/// Production-grade display-name validation, normalization and change policy.
///
/// Pure Dart (no Flutter imports) so every rule here is unit-testable.
///
/// DESIGN NOTES — why these rules
/// ------------------------------
/// The bar is set by what real marketplaces enforce: LinkedIn and Airbnb
/// require a first AND last name and reject symbols/digits; Facebook's
/// real-name policy rejects "unusual capitalization", numbers, and "words or
/// phrases in place of a name"; Facebook gates name changes behind a 60-day
/// cooldown and Instagram behind 14 days. Help24 sits between them: a 30-day
/// cooldown (see [NameChangePolicy]) because a provider's name is a trust
/// signal attached to completed jobs and reviews.
///
/// The overriding constraint is FALSE POSITIVES ARE WORSE THAN FALSE
/// NEGATIVES. Rejecting "Martin King" to catch "KingBoss" would be a bug, not
/// a safeguard. So the vanity check never fires on a substring: it fires only
/// when EVERY word of the name is a vanity token, or when a single glued
/// token (`KingBoss`, `MoneyMaker`) splits on its internal capitals into
/// vanity words. Real names survive; handles do not.
library;

/// Outcome of [NameValidator.check].
class NameCheck {
  /// The cleaned, capitalization-normalized name. Only meaningful when [ok].
  final String normalized;

  /// User-facing reason the name was rejected. Null when [ok].
  final String? error;

  const NameCheck._(this.normalized, this.error);

  const NameCheck.valid(String normalized) : this._(normalized, null);
  const NameCheck.invalid(String error) : this._('', error);

  bool get ok => error == null;
}

class NameValidator {
  NameValidator._();

  static const int minLength = 2;
  static const int maxLength = 60;
  static const int maxWords = 5;

  // Unicode letters (any script), plus the punctuation that legitimately
  // appears inside names. Digits, emoji, @, _, and every other symbol are out.
  static final RegExp _allowedChars = RegExp(r"^[\p{L}\p{M} .'’\-]+$", unicode: true);
  static final RegExp _hasLetter = RegExp(r'\p{L}', unicode: true);
  static final RegExp _tripleRepeat = RegExp(r'(\p{L})\1\1', unicode: true, caseSensitive: false);
  static final RegExp _whitespace = RegExp(r'\s+');

  /// Name particles and prefixes that legitimately carry internal capitals or
  /// sit lowercase between names. Never treated as vanity words.
  static const Set<String> _particles = {
    'mc', 'mac', 'o', 'd', 'de', 'del', 'della', 'di', 'da', 'du', 'la', 'le',
    'van', 'von', 'der', 'den', 'ter', 'bin', 'ibn', 'al', 'el', 'st', 'san',
    'santa', 'abu', 'ben',
  };

  /// Words that are handles, boasts or titles rather than names. Matched only
  /// as WHOLE words (or whole camel-case segments) — never as substrings — so
  /// "Kingsley", "Princeton" and "Bosco" are unaffected.
  static const Set<String> _vanityWords = {
    // boasts / street handles
    'king', 'queen', 'boss', 'money', 'maker', 'cool', 'rich', 'cash', 'dollar',
    'dollars', 'millionaire', 'billionaire', 'legend', 'savage', 'gangsta',
    'gangster', 'killer', 'sniper', 'hustler', 'hustle', 'plug', 'baller',
    'swag', 'vibes', 'wizard', 'ninja', 'beast', 'boy', 'boyz', 'girl', 'girlz',
    'guy', 'dude', 'bro', 'mama', 'papa', 'don', 'chief', 'god', 'lord',
    'master', 'ceo', 'mr', 'mrs', 'ms', 'miss', 'dr', 'prof', 'sir', 'madam',
    'engineer', 'eng',
    // system / placeholder
    'admin', 'administrator', 'support', 'official', 'verified', 'help', 'help24',
    'test', 'testing', 'user', 'username', 'guest', 'anonymous', 'anon',
    'unknown', 'null', 'undefined', 'none', 'nil', 'me', 'myself', 'xxx',
  };

  /// Validate and normalize a display name.
  ///
  /// Returns the normalized value on success (that value — not the raw input —
  /// is what callers should persist).
  static NameCheck check(String raw) {
    final collapsed = raw.trim().replaceAll(_whitespace, ' ');

    if (collapsed.isEmpty) {
      return const NameCheck.invalid('Enter your name.');
    }
    if (collapsed.length < minLength) {
      return const NameCheck.invalid('That name is too short.');
    }
    if (collapsed.length > maxLength) {
      return const NameCheck.invalid('Names can be at most $maxLength characters.');
    }
    if (!_allowedChars.hasMatch(collapsed)) {
      // The single most common rejection — say exactly what is not allowed.
      return const NameCheck.invalid(
        'Use letters only. Numbers, emoji and symbols are not allowed in names.',
      );
    }
    if (!_hasLetter.hasMatch(collapsed)) {
      return const NameCheck.invalid('Enter your real name.');
    }
    if (_tripleRepeat.hasMatch(collapsed)) {
      return const NameCheck.invalid('That does not look like a real name.');
    }

    final words = collapsed.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.length > maxWords) {
      return const NameCheck.invalid('That is too many names. Use up to $maxWords.');
    }

    // First name + last name. A single word is the classic handle shape and
    // is also what every comparable marketplace rejects.
    final substantive = words.where((w) => _lettersOnly(w).length >= 2).length;
    if (words.length < 2 || substantive < 2) {
      return const NameCheck.invalid('Enter your first and last name.');
    }

    for (final word in words) {
      final letters = _lettersOnly(word);
      if (letters.isEmpty) {
        return const NameCheck.invalid('That does not look like a real name.');
      }
      if (letters.length > 30) {
        return const NameCheck.invalid('That name is too long.');
      }
    }

    if (_isVanity(words)) {
      return const NameCheck.invalid(
        'Use your real name. Nicknames and titles are not allowed here.',
      );
    }

    return NameCheck.valid(normalize(collapsed));
  }

  /// True when the name reads as a handle rather than a person.
  ///
  /// Fires when (a) every word is a vanity token, or (b) any single word is a
  /// glued mash-up whose camel-case segments are all vanity tokens
  /// ("KingBoss", "MoneyMaker"). Never fires on a real name that merely
  /// contains one such word ("Martin King").
  static bool _isVanity(List<String> words) {
    bool isVanityToken(String t) {
      final k = _lettersOnly(t).toLowerCase();
      return k.isNotEmpty && _vanityWords.contains(k);
    }

    // (a) whole name is vanity: "Money Maker", "King Boss", "Cool Boy"
    if (words.every(isVanityToken)) return true;

    // (b) a glued handle inside one word: "KingBoss" → [King, Boss]
    for (final word in words) {
      final segments = _splitCamelCase(word);
      if (segments.length < 2) continue;
      if (segments.every((s) => _particles.contains(s.toLowerCase()))) continue;
      if (segments.every(isVanityToken)) return true;
    }
    return false;
  }

  /// Split on internal capitals: "KingBoss" → [King, Boss], "McDonald" →
  /// [Mc, Donald]. Returns a single-element list when there is no split.
  static List<String> _splitCamelCase(String word) {
    final letters = _lettersOnly(word);
    if (letters.length < 4) return [letters];
    final out = <String>[];
    final buffer = StringBuffer();
    for (final rune in letters.runes) {
      final ch = String.fromCharCode(rune);
      final isUpper = ch != ch.toLowerCase() && ch == ch.toUpperCase();
      if (isUpper && buffer.isNotEmpty) {
        out.add(buffer.toString());
        buffer.clear();
      }
      buffer.write(ch);
    }
    if (buffer.isNotEmpty) out.add(buffer.toString());
    return out.isEmpty ? [letters] : out;
  }

  static String _lettersOnly(String s) =>
      s.replaceAll(RegExp(r"[^\p{L}\p{M}]", unicode: true), '');

  /// Capitalization normalization: "john  MWANGI" → "John Mwangi".
  ///
  /// Preserves the forms that are genuinely spelled with internal capitals —
  /// "mcdonald" → "McDonald", "o'brien" → "O'Brien", "jean-pierre" →
  /// "Jean-Pierre" — and keeps nobiliary particles lowercase when they sit
  /// between names ("Ludwig van Beethoven"), never at the start.
  static String normalize(String raw) {
    final words = raw.trim().replaceAll(_whitespace, ' ').split(' ')
      ..removeWhere((w) => w.isEmpty);
    final out = <String>[];
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      final lower = word.toLowerCase();
      final isParticle = _particles.contains(_lettersOnly(lower));
      // A particle keeps its lowercase form only BETWEEN names, and only when
      // it is not the last word either (a surname "De" alone stays "De").
      if (isParticle && i > 0 && i < words.length - 1 && !lower.contains("'")) {
        out.add(lower);
        continue;
      }
      out.add(_capitalizeWord(lower));
    }
    return out.join(' ');
  }

  /// Capitalize one word, splitting on the separators that create a second
  /// capital inside a single name.
  static String _capitalizeWord(String lower) {
    var result = _capitalizeSegments(lower, '-');
    result = _capitalizeSegments(result, '.');
    result = _capitalizeApostrophes(result);
    result = _capitalizeMacPrefix(result);
    return result;
  }

  static String _capitalizeSegments(String value, String separator) {
    if (!value.contains(separator)) return _upperFirst(value);
    return value.split(separator).map(_upperFirst).join(separator);
  }

  /// "o'brien" → "O'Brien", but "d'angelo" → "D'Angelo". A trailing
  /// apostrophe (as in some transliterations) is left alone.
  static String _capitalizeApostrophes(String value) {
    for (final mark in const ["'", '’']) {
      if (!value.contains(mark)) continue;
      final parts = value.split(mark);
      for (var i = 1; i < parts.length; i++) {
        // Only capitalize after a SHORT prefix (O', D', L') — "shaquille'sm"
        // style noise stays untouched, and neither does a possessive tail.
        if (parts[i - 1].replaceAll(RegExp(r'[^A-Za-z]'), '').length <= 2) {
          parts[i] = _upperFirst(parts[i]);
        }
      }
      value = parts.map(_upperFirst).join(mark);
    }
    return value;
  }

  /// "mcdonald" → "McDonald", "macarthur" → "MacArthur". Only applied when the
  /// remainder is long enough to be a name in its own right, so "Mackenzie"
  /// and "Macy" are left as typed.
  static String _capitalizeMacPrefix(String value) {
    final lower = value.toLowerCase();
    for (final prefix in const ['mc', 'mac']) {
      if (!lower.startsWith(prefix)) continue;
      final rest = value.substring(prefix.length);
      if (rest.length < 4) continue;
      return _upperFirst(prefix) + _upperFirst(rest);
    }
    return value;
  }

  static String _upperFirst(String value) {
    if (value.isEmpty) return value;
    return value[0].toUpperCase() + value.substring(1);
  }
}

/// How often a display name may change.
///
/// The cooldown is ADVISORY on the client and AUTHORITATIVE in Postgres:
/// `users_update_own` RLS lets a signed-in user write their own row, so a
/// Dart-only limit would be trivially bypassed. Migration 087 installs a
/// BEFORE UPDATE trigger that owns `users.name_changed_at` and rejects a
/// change inside the window. This class exists so the UI can explain the rule
/// BEFORE the user types, instead of surfacing a database error afterwards.
class NameChangePolicy {
  NameChangePolicy._();

  /// 30 days — the spec's figure, and the same order of magnitude as Facebook
  /// (60d) and Instagram (14d). Long enough that a provider's name stays
  /// stable across a job and its review; short enough for genuine corrections.
  static const Duration cooldown = Duration(days: 30);

  /// When the next change becomes possible. Null means "right now" (the user
  /// has never changed their name).
  static DateTime? nextChangeAllowedAt(DateTime? lastChangedAt) =>
      lastChangedAt?.add(cooldown);

  static bool canChange(DateTime? lastChangedAt, {DateTime? now}) {
    final next = nextChangeAllowedAt(lastChangedAt);
    if (next == null) return true;
    return !(now ?? DateTime.now()).isBefore(next);
  }

  /// Whole days remaining before the next change is allowed (0 when allowed).
  static int daysRemaining(DateTime? lastChangedAt, {DateTime? now}) {
    final next = nextChangeAllowedAt(lastChangedAt);
    if (next == null) return 0;
    final diff = next.difference(now ?? DateTime.now());
    if (diff.isNegative) return 0;
    return diff.inHours ~/ 24 + (diff.inHours % 24 > 0 ? 1 : 0);
  }

  /// One-line explanation for the editor. Null when a change is allowed and
  /// the user has never changed their name (nothing worth saying yet).
  static String? restrictionMessage(DateTime? lastChangedAt, {DateTime? now}) {
    if (lastChangedAt == null) {
      return 'You can change your name once every 30 days.';
    }
    if (canChange(lastChangedAt, now: now)) {
      return 'You can change your name once every 30 days.';
    }
    final days = daysRemaining(lastChangedAt, now: now);
    return days == 1
        ? 'You changed your name recently. You can change it again tomorrow.'
        : 'You changed your name recently. You can change it again in $days days.';
  }
}
