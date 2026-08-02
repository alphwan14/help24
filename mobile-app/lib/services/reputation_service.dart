import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Backend calls go through the authenticated client: it attaches the Firebase
// ID token the server binds identity from, so the ownership checks in each
// backend service actually mean something. See api_client.dart.
import 'api_client.dart';
import '../config/api_config.dart';
import '../models/provider_reputation.dart';
import '../providers/connectivity_provider.dart' show NetworkHealth;

/// Why a reputation read produced no value. The distinction is the difference
/// between "we don't know yet" and "there is nothing to know", and the UI is
/// only honest if it can tell the user which one happened.
enum ReputationOutcome {
  /// A value is present (possibly [ReputationResult.stale]).
  ok,

  /// The device has no usable connection. Not a fact about the provider.
  offline,

  /// Reached the network and still failed — timeout, 5xx, rate limit.
  unavailable,
}

/// A reputation read and WHY it looks the way it does.
@immutable
class ReputationResult {
  final ProviderReputation? rep;
  final ReputationOutcome outcome;

  /// The value came from disk/memory past its freshness window. It is real, it
  /// is just not new; a background refresh is already running.
  final bool stale;

  const ReputationResult(this.rep, this.outcome, {this.stale = false});

  bool get hasValue => rep != null;
}

/// Backend-mediated reputation access. The ONLY way the app obtains provider
/// trust data — there are no direct Supabase reads.
///
/// THREE LAYERS, in order of how fast they answer:
///   1. memory   — a map, answers synchronously, survives navigation
///   2. disk     — SharedPreferences, answers in one async hop, survives RESTART
///   3. network  — [warmAll] for a list (ONE request for N providers), or
///                 [getReputation] for a single provider
///
/// The disk layer is what makes a reopened app show trust signals immediately
/// instead of re-earning them; the batch layer is what makes an applicant list
/// arrive as one thing instead of N things. Stale values are served
/// IMMEDIATELY and refreshed behind the user — a number that is three days old
/// is still a fact, and it beats a spinner in every case.
class ReputationService {
  static const Duration _timeout = Duration(seconds: 15);

  /// Batch warms run on a much shorter leash than a single read: a surface is
  /// waiting to paint on this, and a value we already hold on disk is a better
  /// answer than a fresher one that arrives after the user has moved on.
  static const Duration _warmTimeout = Duration(seconds: 6);

  /// Freshness window: inside it, a cached value is used with no network at
  /// all. Short enough that your OWN profile reflects a new review or approved
  /// job without an app restart.
  static const Duration _cacheTtl = Duration(minutes: 3);

  /// How long a value stays USABLE past [_cacheTtl]. Inside this window a
  /// cached value paints instantly and a refresh runs behind it; past it, the
  /// entry is dropped. Reputation moves over weeks, not minutes — a fourteen
  /// day old tier is still the right thing to show a user on a train.
  static const Duration _staleTtl = Duration(days: 14);

  /// Entries kept on disk. An active client sees a few hundred providers over
  /// a lifetime; the cap keeps one JSON blob from growing without bound.
  static const int _maxPersisted = 400;

  static const String _prefsKey = 'help24_cache_reputation';

  static final Map<String, ({ProviderReputation rep, DateTime at})> _cache = {};
  static final Map<String, Future<ProviderReputation?>> _inflight = {};

  /// Providers whose last network read failed. Kept so a card can distinguish
  /// "still loading" from "we tried and could not" without re-asking.
  static final Map<String, ReputationOutcome> _failures = {};

  /// Provider ids currently covered by an in-flight [warmAll], mapped to that
  /// batch. A single-provider read for one of these WAITS for the batch instead
  /// of racing it — otherwise a card that mounts a frame before the warm-up
  /// lands issues the very request the batch was created to replace, and the
  /// stampede this whole class exists to prevent comes back one card at a time.
  static final Map<String, Future<void>> _batchInflight = {};

  static Future<void>? _restoring;
  static bool _restored = false;

  /// Debounced disk write — a batch warm seeds 40 entries at once and must not
  /// turn into 40 encodes of the whole map.
  static Timer? _persistDebounce;

  // ─── Disk layer ────────────────────────────────────────────────────────────

  /// Pull the persisted cache into memory. Idempotent and safe to call from
  /// anywhere; every network path awaits it first, so a cold start answers from
  /// disk before it ever reaches for the network.
  static Future<void> restore() {
    if (_restored) return Future.value();
    return _restoring ??= _restore();
  }

  static Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        final now = DateTime.now();
        for (final entry in decoded.entries) {
          try {
            final value = entry.value as Map<String, dynamic>;
            final at = DateTime.fromMillisecondsSinceEpoch(value['at'] as int);
            // Anything past the stale window is not worth carrying forward.
            if (now.difference(at) > _staleTtl) continue;
            final rep = ProviderReputation.fromJson(
                Map<String, dynamic>.from(value['row'] as Map));
            if (rep.providerId.isEmpty) continue;
            // Never let disk overwrite something fetched this session.
            _cache.putIfAbsent(rep.providerId, () => (rep: rep, at: at));
          } catch (_) {
            // One bad entry must not cost the whole cache.
          }
        }
        debugPrint('[REPUTATION] restored ${_cache.length} cached providers from disk');
      }
    } catch (e) {
      debugPrint('[REPUTATION] restore failed: $e');
    } finally {
      _restored = true;
    }
  }

  static void _schedulePersist() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_persist());
    });
  }

  static Future<void> _persist() async {
    try {
      // Newest first, so the cap evicts the entries least likely to be wanted.
      final entries = _cache.entries.toList()
        ..sort((a, b) => b.value.at.compareTo(a.value.at));
      final payload = <String, dynamic>{};
      for (final entry in entries.take(_maxPersisted)) {
        payload[entry.key] = {
          'at': entry.value.at.millisecondsSinceEpoch,
          'row': entry.value.rep.toCacheMap(),
        };
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(payload));
    } catch (e) {
      debugPrint('[REPUTATION] persist failed: $e');
    }
  }

  // ─── Memory layer ──────────────────────────────────────────────────────────

  /// Synchronous read of a FRESH cached value. Lets list widgets render
  /// instantly on rebuild instead of flashing a loading placeholder while a
  /// Future.value round-trips the event loop.
  static ProviderReputation? getCachedSync(String providerId) {
    final cached = _cache[providerId];
    if (cached != null && DateTime.now().difference(cached.at) < _cacheTtl) {
      return cached.rep;
    }
    return null;
  }

  /// Synchronous read of any USABLE value — fresh or stale. This is what card
  /// widgets should paint from: a stale tier badge is a true statement, and the
  /// refresh that corrects it is already running.
  static ReputationResult peek(String providerId) {
    final cached = _cache[providerId];
    if (cached != null) {
      final age = DateTime.now().difference(cached.at);
      if (age < _staleTtl) {
        return ReputationResult(cached.rep, ReputationOutcome.ok, stale: age >= _cacheTtl);
      }
    }
    final failure = _failures[providerId];
    if (failure != null) return ReputationResult(null, failure);
    return const ReputationResult(null, ReputationOutcome.ok);
  }

  /// Seed the cache from batch-fetched rows (the `/reputation?ids=` payload and
  /// the public_provider_reputation view share one shape). Rows that fail to
  /// parse are skipped — a bad row must never break the surface it feeds.
  static void seedAll(List<Map<String, dynamic>> rows) {
    final now = DateTime.now();
    var seeded = 0;
    for (final row in rows) {
      try {
        final rep = ProviderReputation.fromJson(row);
        if (rep.providerId.isEmpty) continue;
        _cache[rep.providerId] = (rep: rep, at: now);
        _failures.remove(rep.providerId);
        seeded++;
      } catch (e) {
        debugPrint('[REPUTATION] seedAll: skipped unparsable row: $e');
      }
    }
    if (seeded > 0) _schedulePersist();
  }

  // ─── Network layer ─────────────────────────────────────────────────────────

  /// Fetch reputation for EVERY id in [providerIds] that is not already fresh,
  /// in ONE request. This is the call a list surface makes before it paints, so
  /// that every card in the list has its trust line at the same moment.
  ///
  /// Returns the outcome for the SCREEN, not for any one provider — and it is
  /// about what the screen can SHOW, not about what the network did:
  ///   - [ReputationOutcome.ok]          every provider has something to show
  ///   - [ReputationOutcome.offline]     no connection AND at least one provider
  ///                                     has nothing at all to show
  ///   - [ReputationOutcome.unavailable] reached the network and it failed
  ///
  /// The distinction in the offline case is the point. A list where every card
  /// can draw a real (if slightly old) trust line is a COMPLETE list, and
  /// putting "you're offline, ratings will fill in" above it would be telling
  /// the user something is missing while they are looking at it.
  static Future<ReputationOutcome> warmAll(Iterable<String> providerIds) async {
    await restore();

    final wanted = providerIds.where((id) => id.isNotEmpty).toSet();
    // Worth a request: anything not FRESH — a stale value is shown immediately
    // and corrected by this same batch, at no extra cost, since the request is
    // going out for its siblings anyway.
    final ids = wanted.where((id) => getCachedSync(id) == null).toList();
    if (ids.isEmpty) return ReputationOutcome.ok;

    if (NetworkHealth.isOffline) {
      // Only providers with NOTHING to show are a failure the user can see.
      final blank = ids.where((id) => !peek(id).hasValue).toList();
      for (final id in blank) {
        _failures[id] = ReputationOutcome.offline;
      }
      debugPrint('[REPUTATION] warmAll skipped — offline '
          '(${blank.length}/${ids.length} providers have nothing cached)');
      return blank.isEmpty ? ReputationOutcome.ok : ReputationOutcome.offline;
    }

    // Claim these ids for the duration, so concurrent single reads queue behind
    // this one request instead of firing N of their own.
    final claim = Completer<void>();
    for (final id in ids) {
      _batchInflight[id] = claim.future;
    }
    try {
      return await _runWarm(ids);
    } finally {
      for (final id in ids) {
        if (identical(_batchInflight[id], claim.future)) _batchInflight.remove(id);
      }
      claim.complete();
    }
  }

  static Future<ReputationOutcome> _runWarm(List<String> ids) async {
    try {
      final uri = Uri.parse('${ApiConfig.baseUrl}/reputation')
          .replace(queryParameters: {'ids': ids.join(',')});
      final res = await api.get(uri).timeout(_warmTimeout);
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final rows = (json['reputations'] as List<dynamic>? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        seedAll(rows);
        // Anything the server did not return stays unknown rather than being
        // invented — but it is no longer a FAILURE, so cards fall through to
        // their per-provider read instead of claiming a network problem.
        for (final id in ids) {
          if (_cache.containsKey(id)) _failures.remove(id);
        }
        debugPrint('[REPUTATION] warmAll: ${rows.length}/${ids.length} providers in one request');
        return ReputationOutcome.ok;
      }
      debugPrint('[REPUTATION] warmAll -> ${res.statusCode}');
    } catch (e) {
      debugPrint('[REPUTATION] warmAll error: $e');
    }
    final outcome =
        NetworkHealth.isOffline ? ReputationOutcome.offline : ReputationOutcome.unavailable;
    // Same rule as the offline short-circuit: only a provider with nothing to
    // show is a failure the user can see. One whose stale value is on screen
    // has not failed from where they are sitting.
    final blank = ids.where((id) => !peek(id).hasValue).toList();
    for (final id in blank) {
      _failures[id] = outcome;
    }
    return blank.isEmpty ? ReputationOutcome.ok : outcome;
  }

  /// Reputation summary for a provider. Returns null on error (callers render
  /// an honest unavailable state — never a fabricated value).
  ///
  /// A STALE cached value is returned immediately and refreshed in the
  /// background; the caller gets a real number now and a corrected one shortly.
  static Future<ProviderReputation?> getReputation(String providerId) async =>
      (await getResult(providerId)).rep;

  /// [getReputation] with the reason attached — use this wherever the UI needs
  /// to say something other than "unavailable" when the value is missing.
  static Future<ReputationResult> getResult(String providerId) async {
    if (providerId.isEmpty) {
      return const ReputationResult(null, ReputationOutcome.ok);
    }
    await restore();

    // If a list warm-up already covers this provider, its result is one request
    // away for everyone — wait for it rather than opening a second one.
    final batch = _batchInflight[providerId];
    if (batch != null) await batch;

    final cached = _cache[providerId];
    if (cached != null) {
      final age = DateTime.now().difference(cached.at);
      if (age < _cacheTtl) {
        return ReputationResult(cached.rep, ReputationOutcome.ok);
      }
      if (age < _staleTtl) {
        // Stale-while-revalidate: answer now, correct later.
        unawaited(_refresh(providerId));
        return ReputationResult(cached.rep, ReputationOutcome.ok, stale: true);
      }
    }

    if (NetworkHealth.isOffline) {
      _failures[providerId] = ReputationOutcome.offline;
      return const ReputationResult(null, ReputationOutcome.offline);
    }

    final rep = await _refresh(providerId);
    if (rep != null) return ReputationResult(rep, ReputationOutcome.ok);
    return ReputationResult(null, _failures[providerId] ?? ReputationOutcome.unavailable);
  }

  /// Single-provider network read, deduplicated by provider id.
  static Future<ProviderReputation?> _refresh(String providerId) {
    final existing = _inflight[providerId];
    if (existing != null) return existing;

    final future = _fetchReputation(providerId);
    _inflight[providerId] = future;
    // Block body on purpose. This site happens to be safe — the map holds the
    // INNER future, which has already completed by the time this callback runs
    // — but the arrow form returns Map.remove's value, and whenComplete awaits
    // any Future its callback returns. Storing the composed future here
    // instead would make it await itself and hang forever, silently. Two
    // sibling caches shipped exactly that bug; the block body removes the trap
    // rather than relying on the storage order staying as it is.
    return future.whenComplete(() {
      _inflight.remove(providerId);
    });
  }

  static Future<ProviderReputation?> _fetchReputation(String providerId) async {
    try {
      final res = await api
          .get(Uri.parse('${ApiConfig.baseUrl}/reputation/$providerId'))
          .timeout(_timeout);
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final rep = ProviderReputation.fromJson(json);
        // Classification diagnostics: provider STATUS derives from `tier` only;
        // total_reviews must never influence it. Log the inputs so any future
        // "shows New Provider despite N jobs" report is one log line to diagnose.
        debugPrint(
          '[REPUTATION][LOAD] provider=$providerId tier=${rep.tier} '
          'completed_jobs=${rep.completedJobs} total_reviews=${rep.totalReviews} '
          'dispute_rate=${rep.disputeRate.toStringAsFixed(3)}',
        );
        _cache[providerId] = (rep: rep, at: DateTime.now());
        _failures.remove(providerId);
        _schedulePersist();
        return rep;
      }
      debugPrint('[REPUTATION] getReputation $providerId -> ${res.statusCode}');
      _failures[providerId] = ReputationOutcome.unavailable;
    } catch (e) {
      debugPrint('[REPUTATION] getReputation $providerId error: $e');
      _failures[providerId] = NetworkHealth.isOffline
          ? ReputationOutcome.offline
          : ReputationOutcome.unavailable;
    }
    return null;
  }

  /// Paginated visible reviews for a provider (newest first).
  static Future<ProviderReviewsPage> getProviderReviews(
    String providerId, {
    int limit = 20,
    String? cursor,
  }) async {
    if (providerId.isEmpty) {
      return const ProviderReviewsPage(reviews: [], nextCursor: null);
    }
    try {
      final qp = <String, String>{'limit': '$limit', if (cursor != null) 'cursor': cursor};
      final uri = Uri.parse('${ApiConfig.baseUrl}/reviews/provider/$providerId')
          .replace(queryParameters: qp);
      final res = await api.get(uri).timeout(_timeout);
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (json['reviews'] as List<dynamic>? ?? [])
            .map((e) => ProviderReview.fromJson(e as Map<String, dynamic>))
            .toList();
        return ProviderReviewsPage(reviews: list, nextCursor: json['next_cursor'] as String?);
      }
    } catch (e) {
      debugPrint('[REPUTATION] getProviderReviews $providerId error: $e');
    }
    return const ProviderReviewsPage(reviews: [], nextCursor: null);
  }

  /// Drop a cached entry (e.g. after a review is submitted in a later phase).
  static void invalidate(String providerId) {
    _cache.remove(providerId);
    _failures.remove(providerId);
    _schedulePersist();
  }

  @visibleForTesting
  static void resetForTest() {
    _cache.clear();
    _inflight.clear();
    _failures.clear();
    _persistDebounce?.cancel();
    _restoring = null;
    _restored = false;
  }
}
