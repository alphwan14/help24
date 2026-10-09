/// THE OTHER PERSON IN A CONVERSATION, AS THIS PHONE LAST KNEW THEM.
///
/// WHY THIS EXISTS
/// ---------------
/// A conversation used to carry its participant's name as a copy taken from
/// whichever fetch built the row last. The profile lookup behind that copy ran
/// as a second request after the chat rows, and a failure there was swallowed
/// and answered with the literal name `'?'` — which was then rendered, AND
/// saved to disk over the name the phone had known a moment earlier. Losing
/// signal at the wrong instant (seen on a reconnect, where the network is up
/// but DNS is not yet) turned every row of the Messages tab into "?" for good:
/// the next offline launch read the poisoned copy back.
///
/// Two rules now, enforced here and in `ChatStore`:
///   * a name that is not known is ABSENT, never a placeholder value — nothing
///     may store `'?'` (or any other stand-in) as a person's name;
///   * a name, once known, is only ever replaced by another known name.
library;

class ChatPerson {
  const ChatPerson({
    required this.id,
    this.name,
    this.avatarUrl,
    this.avatarPath,
    this.avatarVersion,
    this.profession,
    this.lastSeen,
  });

  final String id;

  /// Last known display name, or null when this phone has never learned it.
  final String? name;

  /// The profile photo's address on the server.
  final String? avatarUrl;

  /// The photo on THIS phone, downloaded once (see `ChatMediaStore`).
  final String? avatarPath;

  /// Which photo [avatarPath] holds — a hash of the [avatarUrl] it came from,
  /// so a changed photo is fetched again and an unchanged one never is.
  final String? avatarVersion;

  /// `users.profession` — a registry key or legacy text.
  final String? profession;

  final DateTime? lastSeen;
}

/// The rules for showing a person, in one place.
class ChatPeople {
  ChatPeople._();

  /// What a person is called when this phone has never learned their name.
  ///
  /// Words, not a symbol: "?" reads as an error, and as a NAME it is worse than
  /// none — it is what made eight different people look like one. Reaching
  /// this needs a conversation synced while its participant's profile could
  /// not be read even once; the next good sync replaces it.
  static const String unknownName = 'Help24 member';

  /// Whether [name] is a real name worth storing or showing.
  ///
  /// `'?'` is refused explicitly because builds before the chat database wrote
  /// it as a name: an imported cache must not carry the poison forward.
  static bool isKnownName(String? name) {
    final trimmed = name?.trim() ?? '';
    return trimmed.isNotEmpty && trimmed != '?';
  }

  /// [name] when known, otherwise null. Use at every WRITE boundary.
  static String? knownOrNull(String? name) => isKnownName(name) ? name!.trim() : null;

  /// The name to render. Never empty, never "?".
  static String displayName(String? name) =>
      isKnownName(name) ? name!.trim() : unknownName;

  /// Up to two initials from a known name — "Alphonse Lincoln" → "AL",
  /// "pauline" → "P". Empty when the name is not known: the avatar then draws
  /// a person glyph rather than inventing letters.
  static String initials(String? name) {
    if (!isKnownName(name)) return '';
    final words = name!
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '';
    String first(String w) => String.fromCharCode(w.runes.first).toUpperCase();
    if (words.length == 1) return first(words.first);
    return '${first(words.first)}${first(words.last)}';
  }

  /// A stable index into `PersonTint`'s palette for [userId].
  ///
  /// FNV-1a over the id's code units: the same person gets the same colour on
  /// every screen, every launch and every phone. `String.hashCode` is not
  /// stable across runs, so it cannot be used for this.
  static int tintIndex(String userId) {
    var hash = 0x811c9dc5;
    for (final unit in userId.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }
}
