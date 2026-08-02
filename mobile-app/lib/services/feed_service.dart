import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

// Backend calls go through the authenticated client: it attaches the Firebase
// ID token the server binds identity from, so the ownership checks in each
// backend service actually mean something. See api_client.dart.
import 'api_client.dart';

import '../config/api_config.dart';
import '../models/post_model.dart';
import '../utils/feed_scope.dart';
import 'post_service.dart';

/// Where a feed page actually came from. Surfaced so the UI (and QA) can tell
/// a ranked feed from a fallback one without guessing.
enum FeedSource {
  /// Ranked by the backend recommendation engine.
  ranked,

  /// The engine was unreachable — this is the plain Supabase read the app has
  /// always used, ordered by `created_at DESC`.
  fallback,
}

/// One signal's contribution to one post's score — the explainability payload.
class FeedSignalBreakdown {
  final String key;
  final String label;
  final double points;
  final double raw;

  const FeedSignalBreakdown({
    required this.key,
    required this.label,
    required this.points,
    required this.raw,
  });

  factory FeedSignalBreakdown.fromJson(Map<String, dynamic> json) =>
      FeedSignalBreakdown(
        key: json['key']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        points: _toDouble(json['points']),
        raw: _toDouble(json['raw']),
      );

  static double _toDouble(dynamic v) =>
      v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

  /// "Distance +28.4" — the form the debug overlay renders.
  @override
  String toString() =>
      '$label ${points >= 0 ? '+' : ''}${points.toStringAsFixed(1)}';
}

/// One ranked page of `T` (PostModel for Discover, JobModel for Jobs).
class FeedResult<T> {
  final List<T> items;
  final FeedSource source;
  final bool hasMore;

  /// `postId → final score`. Empty on the fallback path.
  final Map<String, double> scores;

  /// `postId → per-signal breakdown`. Empty on the fallback path.
  /// Consumed by the debug overlay only — never by layout.
  final Map<String, List<FeedSignalBreakdown>> signals;

  /// Whether the server personalised this page (profession / behaviour known).
  final bool personalised;

  /// The server's bucketed ranking clock for this page, when it sent one.
  ///
  /// Two pages sharing an epoch were scored against the same instant, so any
  /// difference between them is a real change in the corpus or the viewer
  /// rather than time passing. Null on the fallback path — a chronological read
  /// has no ranking epoch to report.
  final String? rankingEpoch;

  const FeedResult({
    required this.items,
    required this.source,
    this.hasMore = false,
    this.scores = const {},
    this.signals = const {},
    this.personalised = false,
    this.rankingEpoch,
  });

  bool get isRanked => source == FeedSource.ranked;
}

/// Client for the Discover recommendation engine (`GET /feed`).
///
/// THE CONTRACT THAT MATTERS
/// -------------------------
/// The feed must render even when ranking cannot. Every failure path here —
/// timeout, 5xx, malformed body, no network — falls through to the exact
/// Supabase query the app used before this engine existed. A user never sees
/// "ranking is down"; at worst they see a chronological feed, which is what
/// they saw last month.
///
/// Same contract as promotion serving (`PromotionService.fetchSlots`): an
/// optional backend must never be able to break a core surface.
class FeedService {
  /// Short on purpose. Ranking that takes longer than this is worse than
  /// recency that arrives now — the fallback is genuinely good, not a stub.
  static const Duration _timeout = Duration(seconds: 8);

  // ── Discover ───────────────────────────────────────────────────────────────

  /// One ranked page of requests/offers for Discover.
  ///
  /// [scope] matches the tab bar. It is a [FeedScope], not a string, because it
  /// drives BOTH the `scope=` parameter the engine reads and the type/status
  /// filters the fallback query applies — and those two must never disagree
  /// about what belongs in Discover.
  ///
  /// [filters] carries the user's EXPLICIT filters, which the server applies as
  /// hard constraints — ranking never overrides what someone asked for.
  /// [warmFallback] is an already-in-flight chronological read (the splash
  /// prefetch) offered as the degradation source. It saves a round trip on the
  /// one path that needs it — a backend too cold to rank — and is ignored
  /// entirely when ranking succeeds. It is never PAINTED before the ranked
  /// result: painting a chronological page and replacing it a second later is
  /// exactly the cold-start reshuffle this engine had to stop doing.
  static Future<FeedResult<PostModel>> fetchFeed({
    String? userId,
    double? latitude,
    double? longitude,
    FeedScope scope = FeedScope.all,
    PostFilters? filters,
    int page = 0,
    int? pageSize,
    Future<List<PostModel>?>? warmFallback,
  }) {
    return _fetch<PostModel>(
      userId: userId,
      latitude: latitude,
      longitude: longitude,
      scope: scope,
      filters: filters,
      page: page,
      pageSize: pageSize,
      parse: PostModel.fromJson,
      idOf: (post) => post.id,
      fallback: () async =>
          (warmFallback == null ? null : await warmFallback) ??
          await PostService.fetchPosts(filters: _forScope(filters, scope)),
    );
  }

  // ── Jobs ───────────────────────────────────────────────────────────────────

  /// One ranked page of job posts.
  ///
  /// The Jobs tab has always been a second, weaker copy of the feed query
  /// (audit §3.11): same table, narrower search, no ranking. It now runs
  /// through the same engine with `scope=jobs`, so an electrician sees
  /// electrical jobs first here for the same reason they do in Discover.
  static Future<FeedResult<JobModel>> fetchJobsFeed({
    String? userId,
    double? latitude,
    double? longitude,
    PostFilters? filters,
    int page = 0,
    int? pageSize,
  }) {
    return _fetch<JobModel>(
      userId: userId,
      latitude: latitude,
      longitude: longitude,
      scope: FeedScope.jobs,
      filters: filters,
      page: page,
      pageSize: pageSize,
      parse: JobModel.fromJson,
      idOf: (job) => job.id,
      // Scoped like Discover's fallback. `fetchJobs` fixes the type itself, but
      // the browsing STATUS rule has to be passed in or the fallback shows
      // filled roles the ranked path excludes.
      fallback: () async =>
          PostService.fetchJobs(filters: _forScope(filters, FeedScope.jobs)),
    );
  }

  // ── shared request / parse / degrade ───────────────────────────────────────

  static Future<FeedResult<T>> _fetch<T>({
    required String? userId,
    required double? latitude,
    required double? longitude,
    required FeedScope scope,
    required PostFilters? filters,
    required int page,
    required int? pageSize,
    required T Function(Map<String, dynamic>) parse,
    required String Function(T) idOf,
    required Future<List<T>> Function() fallback,
  }) async {
    try {
      final uri = Uri.parse('${ApiConfig.baseUrl}/feed').replace(
        queryParameters: _queryParams(
          userId: userId,
          latitude: latitude,
          longitude: longitude,
          scope: scope,
          filters: filters,
          page: page,
          pageSize: pageSize,
        ),
      );

      final response = await api.get(uri).timeout(_timeout);
      if (response.statusCode != 200) {
        debugPrint('[FEED] ranked feed ${response.statusCode} — falling back');
        return _degrade(fallback);
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final result = _parse<T>(body, parse, idOf);

      // An empty ranked first page is indistinguishable from a retrieval
      // problem, and "No posts found — try adjusting your filters" is a costly
      // thing to say wrongly. Confirm against the direct read before believing
      // it.
      if (result.items.isEmpty && page == 0) {
        debugPrint('[FEED] ranked feed empty — confirming against Supabase');
        return _degrade(fallback);
      }

      return result;
    } catch (e) {
      debugPrint('[FEED] ranked feed failed ($e) — falling back');
      return _degrade(fallback);
    }
  }

  /// Run the pre-engine query. Deliberately NOT wrapped in a try: it throws
  /// exactly what `PostService` throws, so `AppProvider` keeps distinguishing
  /// "failed to load" from "nothing here".
  static Future<FeedResult<T>> _degrade<T>(
    Future<List<T>> Function() fallback,
  ) async {
    return FeedResult<T>(items: await fallback(), source: FeedSource.fallback);
  }

  static Map<String, String> _queryParams({
    required String? userId,
    required double? latitude,
    required double? longitude,
    required FeedScope scope,
    required PostFilters? filters,
    required int page,
    required int? pageSize,
  }) {
    // The viewer's UTC offset drives the time-of-day signal. Without it the
    // server would rank a Nairobi morning as though it were the middle of the
    // night, because the server's timezone is an accident of hosting.
    final tzOffset = DateTime.now().timeZoneOffset.inMinutes;

    return {
      'scope': scope.wire,
      'page': '$page',
      'tz_offset': '$tzOffset',
      if (userId != null && userId.isNotEmpty) 'user_id': userId,
      if (latitude != null) 'lat': '$latitude',
      if (longitude != null) 'lng': '$longitude',
      if (pageSize != null) 'page_size': '$pageSize',
      if (filters?.searchQuery != null && filters!.searchQuery!.trim().isNotEmpty)
        'q': filters.searchQuery!.trim(),
      if (filters?.categories != null && filters!.categories!.isNotEmpty)
        'categories': filters.categories!.join(','),
      if (filters?.city != null && filters!.city!.isNotEmpty) 'city': filters.city!,
      if (filters?.area != null && filters!.area!.isNotEmpty) 'area': filters.area!,
      if (filters?.urgency != null && filters!.urgency!.isNotEmpty)
        'urgency': filters.urgency!,
      if (filters?.difficulty != null && filters!.difficulty!.isNotEmpty)
        'difficulty': filters.difficulty!,
      if (filters?.minPrice != null) 'min_price': '${filters!.minPrice}',
      if (filters?.maxPrice != null) 'max_price': '${filters!.maxPrice}',
    };
  }

  static FeedResult<T> _parse<T>(
    Map<String, dynamic> body,
    T Function(Map<String, dynamic>) parse,
    String Function(T) idOf,
  ) {
    final rawItems = body['items'];
    if (rawItems is! List) {
      return const FeedResult(items: [], source: FeedSource.ranked)
          as FeedResult<T>;
    }

    final items = <T>[];
    final scores = <String, double>{};
    final signals = <String, List<FeedSignalBreakdown>>{};

    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final postJson = raw['post'];
      if (postJson is! Map) continue;

      // Parsed with the SAME fromJson the direct Supabase read uses — the
      // server hydrates with a byte-identical select shape, so a ranked row and
      // a fallback row are indistinguishable to every widget downstream.
      final item = parse(Map<String, dynamic>.from(postJson));
      items.add(item);

      final id = idOf(item);
      final score = raw['score'];
      if (score is num) scores[id] = score.toDouble();

      final rawSignals = raw['signals'];
      if (rawSignals is List) {
        signals[id] = [
          for (final s in rawSignals)
            if (s is Map)
              FeedSignalBreakdown.fromJson(Map<String, dynamic>.from(s)),
        ];
      }
    }

    return FeedResult<T>(
      items: items,
      source: FeedSource.ranked,
      hasMore: body['has_more'] == true,
      scores: scores,
      signals: signals,
      personalised: body['personalised'] == true,
      rankingEpoch: body['ranking_epoch']?.toString(),
    );
  }

  /// Restrict [filters] to [scope] for the fallback query.
  ///
  /// This method used to translate the scope into a SINGLE `type` string and
  /// map `all` to null — no type filter and no status filter — which is how the
  /// fallback path came to show job posts and every non-open listing that the
  /// ranked path excludes. `PostFilters.forScope` now applies both rules from
  /// the one definition in utils/feed_scope.dart.
  static PostFilters _forScope(PostFilters? filters, FeedScope scope) =>
      (filters ?? const PostFilters()).forScope(scope);
}
