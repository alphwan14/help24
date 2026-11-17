import '../config/post_intent_phrases.dart';
import '../models/post_model.dart';

/// Does this text read like a request or like an offer?
///
/// A light, explainable check, not a model: whole-word matches from the lists
/// in config/post_intent_phrases.dart (a phrase counts 2, a hint 1), longest
/// first so no word is counted twice. The composer uses the answer only to
/// SUGGEST a switch; it never blocks posting, and a tie says nothing.
///
/// ── Where it looks ───────────────────────────────────────────────────────
/// Anywhere in the title and the description together, in any case, with
/// punctuation ignored: "Help24 test I am a plumber please ignore" is caught
/// by "i am a" in the middle of the title, and the same words in the
/// description count the same. Matching is by WHOLE WORDS, not raw
/// substrings, on purpose: "am a" must not fire inside "Kama" or "drama",
/// and "need" must not fire inside "needle".
///
/// The admin console runs the same check over live listings
/// (admin-dashboard/lib/post-intent.ts). Its phrase lists are a copy of
/// config/post_intent_phrases.dart, and a console test fails if the two
/// drift apart.
class PostIntentReading {
  const PostIntentReading({
    required this.offerPhrases,
    required this.requestPhrases,
    required this.offerScore,
    required this.requestScore,
  });

  /// The offer phrases and hints found, in the order they appear.
  final List<String> offerPhrases;

  /// The request phrases and hints found, in the order they appear.
  final List<String> requestPhrases;

  final int offerScore;
  final int requestScore;

  /// The kind the words lean towards, or null when they do not lean.
  PostType? get leaning {
    if (offerScore > requestScore) return PostType.offer;
    if (requestScore > offerScore) return PostType.request;
    return null;
  }
}

const int _phraseWeight = 2;
const int _hintWeight = 1;

class _Phrase {
  const _Phrase(this.tokens, this.type, this.source, this.weight, this.order);
  final List<String> tokens;
  final PostType type;
  final String source;
  final int weight;

  /// Position in the lists, so the order of equals never depends on the
  /// sort's whim (Dart's sort is not stable).
  final int order;
}

class _Match {
  const _Match(this.start, this.phrase);
  final int start;
  final _Phrase phrase;
  int get end => start + phrase.tokens.length;
}

/// Lower case, apostrophes removed, everything that is not a letter or a
/// digit turned into a word break.
List<String> _tokens(String text) {
  final cleaned = text
      .toLowerCase()
      .replaceAll(RegExp("['’‘`]"), '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  return cleaned.isEmpty ? const [] : cleaned.split(' ');
}

List<_Phrase>? _compiled;

/// Every list, tokenised once. Longest first; at equal length a phrase before
/// a hint; then list order.
List<_Phrase> _phrases() {
  final cached = _compiled;
  if (cached != null) return cached;
  var order = 0;
  final all = <_Phrase>[];
  void add(List<String> list, PostType type, int weight) {
    for (final p in list) {
      final tokens = _tokens(p);
      if (tokens.isNotEmpty) all.add(_Phrase(tokens, type, p, weight, order++));
    }
  }

  add(kOfferPhrases, PostType.offer, _phraseWeight);
  add(kRequestPhrases, PostType.request, _phraseWeight);
  add(kOfferHints, PostType.offer, _hintWeight);
  add(kRequestHints, PostType.request, _hintWeight);
  all.sort((a, b) {
    final byLength = b.tokens.length.compareTo(a.tokens.length);
    if (byLength != 0) return byLength;
    final byWeight = b.weight.compareTo(a.weight);
    if (byWeight != 0) return byWeight;
    return a.order.compareTo(b.order);
  });
  return _compiled = all;
}

bool _matchesAt(List<String> words, int start, List<String> tokens) {
  if (start + tokens.length > words.length) return false;
  for (var i = 0; i < tokens.length; i++) {
    if (words[start + i] != tokens[i]) return false;
  }
  return true;
}

/// Read [text]. Every word is claimed by at most one phrase, the longest one
/// that fits there.
PostIntentReading readPostIntent(String text) {
  final words = _tokens(text);
  if (words.isEmpty) {
    return const PostIntentReading(
      offerPhrases: [],
      requestPhrases: [],
      offerScore: 0,
      requestScore: 0,
    );
  }
  final claimed = List<bool>.filled(words.length, false);
  final found = <_Match>[];
  for (final phrase in _phrases()) {
    for (var start = 0; start < words.length; start++) {
      if (!_matchesAt(words, start, phrase.tokens)) continue;
      final end = start + phrase.tokens.length;
      var free = true;
      for (var i = start; i < end; i++) {
        if (claimed[i]) {
          free = false;
          break;
        }
      }
      if (!free) continue;
      for (var i = start; i < end; i++) {
        claimed[i] = true;
      }
      found.add(_Match(start, phrase));
    }
  }
  found.sort((a, b) => a.start.compareTo(b.start));
  int score(PostType type) => found
      .where((m) => m.phrase.type == type)
      .fold(0, (sum, m) => sum + m.phrase.weight);
  return PostIntentReading(
    offerPhrases: [
      for (final m in found)
        if (m.phrase.type == PostType.offer) m.phrase.source,
    ],
    requestPhrases: [
      for (final m in found)
        if (m.phrase.type == PostType.request) m.phrase.source,
    ],
    offerScore: score(PostType.offer),
    requestScore: score(PostType.request),
  );
}

/// A suggestion, and the words it rests on.
class PostIntentSuggestion {
  const PostIntentSuggestion(this.type, this.evidence);

  /// The kind the words read as.
  final PostType type;

  /// The phrases and hints that read that way, as written in the lists.
  final Set<String> evidence;
}

/// What to suggest instead of [chosen], or null to say nothing.
///
/// Only a request and an offer are ever swapped for each other. A job has its
/// own form, so a job is never nudged and nothing is nudged into one.
PostIntentSuggestion? suggestPostType({
  required PostType chosen,
  required String title,
  String description = '',
}) {
  if (chosen == PostType.job) return null;
  final reading = readPostIntent('$title\n$description');
  final leaning = reading.leaning;
  if (leaning == null || leaning == chosen) return null;
  return PostIntentSuggestion(
    leaning,
    {...(leaning == PostType.offer ? reading.offerPhrases : reading.requestPhrases)},
  );
}

/// The type to suggest instead of [chosen], or null to say nothing.
PostType? suggestedPostType({
  required PostType chosen,
  required String title,
  String description = '',
}) =>
    suggestPostType(chosen: chosen, title: title, description: description)?.type;

/// Whether the nudge should show, given what the person already answered.
///
/// "Keep as a request" quiets the nudge for the words it was shown for, not
/// for the rest of the post: if the description then adds NEW words that
/// read the other way ("we offer repairs"), the nudge comes back once more.
/// The same words, or fewer, stay quiet; typing on never brings it back.
bool showPostIntentNudge({
  required PostIntentSuggestion? suggestion,
  required PostType chosen,
  PostType? keptType,
  Set<String> keptEvidence = const {},
}) {
  if (suggestion == null) return false;
  if (keptType != chosen) return true;
  return !keptEvidence.containsAll(suggestion.evidence);
}

/// The nudge, in words. One place, so the composer and its tests agree.
String postIntentNudge(PostType suggested) => suggested == PostType.offer
    ? "This sounds like you're offering a service. Post as an offer?"
    : 'This sounds like you need help. Post as a request?';

/// The label of the one-tap switch.
String postIntentSwitchLabel(PostType suggested) =>
    suggested == PostType.offer ? 'Post as an offer' : 'Post as a request';
