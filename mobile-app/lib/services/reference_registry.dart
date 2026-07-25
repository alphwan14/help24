import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The one loading contract every Help24 reference dataset uses.
///
/// A "reference dataset" is controlled vocabulary the product needs BEFORE it
/// can render a screen — locations, professions, categories. It has three
/// properties that make it different from ordinary data:
///
///   1. it must be available on the FIRST frame (a picker may not spin),
///   2. it must work with no network at all (Kenya, on a matatu, no data),
///   3. it must grow without an app release (a new town, a new trade).
///
/// Those three pull in opposite directions, so the resolution order is fixed
/// and identical for every dataset:
///
///   bundled asset  →  device cache  →  server
///   (always there)    (last known)     (authoritative, versioned)
///
/// Each step only ever *upgrades* what is in memory, and every step is allowed
/// to fail silently. The worst possible outcome is the app behaving exactly
/// like the build that shipped — never an error, never an empty list.
///
/// VERSIONING
/// ----------
/// Every payload carries an integer `version`. A subclass refuses any payload
/// whose version is lower than what is already loaded, which is what makes the
/// three sources safe to combine in any order and makes a server fetch cheap:
/// [fetchRemote] is handed the version already in hand and returns null when
/// the server has nothing newer, so the common case costs ONE small row read
/// instead of pulling several hundred rows every day.
///
/// Adding a new dataset (or a new country's dataset) is a subclass plus a JSON
/// asset. No new caching code, no new failure modes.
abstract class ReferenceRegistry {
  /// Short name used in logs and to namespace the device cache keys.
  String get debugName;

  /// Bundled JSON asset — the offline floor. Must always parse.
  String get assetPath;

  /// How long a device cache is trusted before the server is consulted again.
  /// Expiry never invalidates the cache; it only permits a refresh attempt.
  Duration get ttl => const Duration(hours: 24);

  /// Version currently held in memory. 0 when nothing has loaded yet.
  int get loadedVersion;

  /// Install a payload. Returns false when the payload is unusable (wrong
  /// shape, empty, or older than what is already loaded) — the caller then
  /// leaves the previous state untouched.
  bool applyPayload(Map<String, dynamic> payload);

  /// Ask the server for something newer than [haveVersion]. Return null when
  /// the server has nothing newer, is unreachable, or the table does not exist
  /// yet (migrations not applied). MUST NOT throw.
  Future<Map<String, dynamic>?> fetchRemote(int haveVersion);

  String get _cacheKey => 'refreg_${debugName}_payload_v1';
  String get _cacheAtKey => 'refreg_${debugName}_at_v1';

  Future<void>? _inflight;
  bool _assetLoaded = false;

  /// True once something — anything — is loaded. Reads are safe before this;
  /// they simply answer from an empty dataset until the asset lands (one frame
  /// in practice, because [warmUp] runs at app start).
  bool get isLoaded => loadedVersion > 0;

  /// Load bundled → cache → server. Safe to call from anywhere, as often as
  /// you like: concurrent calls share one in-flight future. Never throws.
  Future<void> warmUp() {
    return _inflight ??= _load().whenComplete(() => _inflight = null);
  }

  /// Guarantees the BUNDLED data is in memory, and nothing more. Used by
  /// screens that open before [warmUp] has had a chance to finish — it is a
  /// pure asset read, so it resolves in a frame or two and never touches the
  /// network or disk cache.
  Future<void> ensureBundled() async {
    if (isLoaded) return;
    await _loadAsset();
  }

  Future<void> _loadAsset() async {
    if (_assetLoaded) return;
    try {
      final raw = await rootBundle.loadString(assetPath);
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && applyPayload(decoded)) {
        _assetLoaded = true;
        debugPrint('[$debugName] bundled asset loaded (v${decoded['version']})');
      }
    } catch (e) {
      // A missing/corrupt asset is a build error, not a runtime scenario —
      // but it must still not crash a user's app.
      debugPrint('[$debugName] bundled asset failed: $e');
    }
  }

  Future<void> _load() async {
    // 1. Bundled first, ALWAYS. It costs one asset read and guarantees that
    //    everything after this point is an optimisation rather than a
    //    dependency — including the cache read, which can be slow on a cold
    //    SharedPreferences.
    await _loadAsset();

    SharedPreferences? prefs;
    var cacheFresh = false;
    try {
      prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      if (cached != null) {
        final decoded = jsonDecode(cached);
        if (decoded is Map<String, dynamic>) {
          // applyPayload rejects it when the shipped asset is newer, which is
          // exactly what should happen after an app update.
          applyPayload(decoded);
        }
      }
      final at = DateTime.fromMillisecondsSinceEpoch(prefs.getInt(_cacheAtKey) ?? 0);
      cacheFresh = DateTime.now().difference(at) < ttl;
    } catch (e) {
      debugPrint('[$debugName] cache read failed: $e');
    }

    // 2. Within the TTL there is nothing to gain from a round trip.
    if (cacheFresh) return;

    // 3. Server. Handed the version we already have so it can answer "nothing
    //    newer" with a single row instead of the whole table.
    try {
      final fresh = await fetchRemote(loadedVersion);
      if (fresh == null) {
        // Nothing newer (or unreachable). Either way the current data is good;
        // stamp the cache so we do not re-ask on every screen for 24h.
        await prefs?.setInt(_cacheAtKey, DateTime.now().millisecondsSinceEpoch);
        return;
      }
      if (applyPayload(fresh)) {
        await prefs?.setString(_cacheKey, jsonEncode(fresh));
        await prefs?.setInt(_cacheAtKey, DateTime.now().millisecondsSinceEpoch);
        debugPrint('[$debugName] server payload applied (v${fresh['version']})');
      }
    } catch (e) {
      debugPrint('[$debugName] remote refresh failed (keeping current data): $e');
    }
  }

  /// Reads `registry_versions` — ONE row, a few bytes — to decide whether a
  /// full pull is worth it. This is what keeps daily sync cost flat as the
  /// datasets grow from hundreds of rows to tens of thousands.
  ///
  /// Returns null when the version is not newer, the table is missing, or the
  /// read fails; the caller then skips the expensive query entirely.
  @protected
  Future<int?> remoteVersionIfNewer(String registryKey, int haveVersion) async {
    try {
      final row = await Supabase.instance.client
          .from('registry_versions')
          .select('version')
          .eq('key', registryKey)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      if (row == null) return null;
      final v = row['version'];
      if (v is! int || v <= haveVersion) return null;
      return v;
    } catch (e) {
      debugPrint('[$debugName] version probe failed: $e');
      return null;
    }
  }

  /// Test seam — drops everything so the next [warmUp] starts clean.
  @protected
  @visibleForTesting
  void resetLoadState() {
    _assetLoaded = false;
    _inflight = null;
  }
}

/// Diacritic- and case-insensitive normalisation used by every reference
/// search. Kept in one place so "Murang'a", "muranga" and "MURANGA" are the
/// same string to the index, on every dataset.
String normalizeForSearch(String input) {
  final lower = input.toLowerCase().trim();
  final buffer = StringBuffer();
  var lastWasSpace = false;
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    final folded = _diacritics[ch] ?? ch;
    // Apostrophes, hyphens and punctuation are dropped rather than turned into
    // spaces: people type "murangà", "murang a" and "muranga" for one town.
    if (RegExp(r'[a-z0-9]').hasMatch(folded)) {
      buffer.write(folded);
      lastWasSpace = false;
    } else if (folded == ' ' && !lastWasSpace) {
      buffer.write(' ');
      lastWasSpace = true;
    }
  }
  return buffer.toString().trim();
}

const Map<String, String> _diacritics = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
  'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
  'ñ': 'n', 'ç': 'c', 'ÿ': 'y',
};

/// A search index over a fixed list of entries.
///
/// Two things make this fast enough to run on EVERY keystroke of a 500-entry
/// (and one day 50,000-entry) dataset without a debounce:
///
///   • a 2-character prefix bucket map, so a query of 2+ characters only scans
///     the entries that could possibly match instead of the whole list;
///   • memoisation of the last query, so a widget rebuild storm (which Flutter
///     produces freely) re-renders without re-searching.
///
/// Ranking is prefix-first: what you typed matching the START of a name beats
/// matching the middle of one, and an exact match beats everything. Within a
/// tier the dataset's own weight decides, so "na" surfaces Nairobi and Nakuru
/// before Naitiri.
class SearchIndex<T> {
  final List<T> _entries;
  final List<_IndexedEntry> _indexed;
  final Map<String, List<int>> _buckets = {};

  String? _lastQuery;
  List<T> _lastResults = const [];

  SearchIndex(
    List<T> entries, {
    required String Function(T) name,
    required int Function(T) weight,
    List<String> Function(T)? aliases,
    List<String> Function(T)? context,
  })  : _entries = entries,
        _indexed = List<_IndexedEntry>.generate(entries.length, (i) {
          final e = entries[i];
          return _IndexedEntry(
            name: normalizeForSearch(name(e)),
            aliases: (aliases?.call(e) ?? const []).map(normalizeForSearch).toList(),
            context: (context?.call(e) ?? const []).map(normalizeForSearch).toList(),
            weight: weight(e),
          );
        }) {
    for (var i = 0; i < _indexed.length; i++) {
      for (final token in _indexed[i].tokens) {
        if (token.length < 2) continue;
        _buckets.putIfAbsent(token.substring(0, 2), () => <int>[]).add(i);
      }
    }
  }

  int get length => _entries.length;

  /// Ranked matches for [rawQuery], best first. An empty query returns const []
  /// — callers show their own browse list, which is a different thing.
  List<T> search(String rawQuery, {int limit = 60}) {
    final q = normalizeForSearch(rawQuery);
    if (q.isEmpty) return const [];
    if (q == _lastQuery) return _lastResults;

    // 2+ chars → only the entries that share a 2-char token prefix can match a
    // prefix or word-start hit. Substring-only hits are rarer and still caught
    // because every token of every entry is bucketed, not just the first.
    final Iterable<int> candidates =
        q.length >= 2 ? (_buckets[q.substring(0, 2)] ?? const <int>[]) : _allIndices;

    final scored = <_Scored>[];
    final seen = <int>{};
    for (final i in candidates) {
      if (!seen.add(i)) continue;
      final score = _indexed[i].score(q);
      if (score > 0) scored.add(_Scored(i, score));
    }

    // A 2-char bucket cannot contain pure-substring matches ("ndo" inside
    // "Kandara"). Those matter for long place and profession names, so a short
    // result set falls back to a full scan — bounded, and only when the fast
    // path did not already answer the question.
    if (scored.length < 8 && q.length >= 2) {
      for (var i = 0; i < _indexed.length; i++) {
        if (!seen.add(i)) continue;
        final score = _indexed[i].score(q);
        if (score > 0) scored.add(_Scored(i, score));
      }
    }

    scored.sort((a, b) {
      if (a.score != b.score) return b.score.compareTo(a.score);
      return _indexed[a.index].name.compareTo(_indexed[b.index].name);
    });

    final results = <T>[];
    for (final s in scored) {
      if (results.length >= limit) break;
      results.add(_entries[s.index]);
    }
    _lastQuery = q;
    _lastResults = results;
    return results;
  }

  Iterable<int> get _allIndices sync* {
    for (var i = 0; i < _indexed.length; i++) {
      yield i;
    }
  }
}

class _Scored {
  final int index;
  final int score;
  const _Scored(this.index, this.score);
}

class _IndexedEntry {
  final String name;
  final List<String> aliases;

  /// Secondary text that should match but never outrank the name itself —
  /// the county for a place, the category for a profession.
  final List<String> context;
  final int weight;
  final List<String> _words;

  _IndexedEntry({
    required this.name,
    required this.aliases,
    required this.context,
    required this.weight,
  }) : _words = name.split(' ').where((w) => w.isNotEmpty).toList();

  /// Every string worth bucketing: the name, each of its words, and each alias.
  Iterable<String> get tokens sync* {
    yield name;
    yield* _words;
    for (final a in aliases) {
      yield a;
      for (final w in a.split(' ')) {
        if (w.isNotEmpty) yield w;
      }
    }
  }

  int score(String q) {
    if (name == q) return 10000 + weight;
    // An EXACT alias hit outranks a partial name hit, and deliberately so:
    // "msa" is exactly what people call Mombasa, and it should not lose to
    // Msambweni merely because that town's name happens to start with the same
    // three letters. A whole known nickname is a stronger signal than a
    // fragment of a name.
    for (final a in aliases) {
      if (a == q) return 9000 + weight;
    }
    if (name.startsWith(q)) return 8000 + weight;
    for (final w in _words) {
      if (w.startsWith(q)) return 6000 + weight;
    }
    for (final a in aliases) {
      if (a.startsWith(q)) return 5000 + weight;
    }
    if (name.contains(q)) return 3000 + weight;
    for (final a in aliases) {
      if (a.contains(q)) return 2000 + weight;
    }
    for (final c in context) {
      if (c.startsWith(q)) return 1500 + weight;
      if (c.contains(q)) return 800 + weight;
    }
    return 0;
  }
}
