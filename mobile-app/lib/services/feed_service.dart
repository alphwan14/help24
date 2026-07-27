import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/post_model.dart';
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

  const FeedResult({
    required this.items,
    required this.source,
    this.hasMore = false,
    this.scores = const {},
    this.signals = const {},
    this.personalised = false,
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
  /// [scope] is `all` | `requests` | `offers`, matching the tab bar.
  /// [filters] carries the user's EXPLICIT filters, which the server applies as
  /// hard constraints — ranking never overrides what someone asked for.
  static Future<FeedResult<PostModel>> fetchFeed({
    String? userId,
    double? latitude,
    double? longitude,
    String scope = 'all',
    PostFilters? filters,
    int page = 0,
    int? pageSize,
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
      fallback: () async => PostService.fetchPosts(
        filters: _withScopeType(filters, scope),
      ),
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
      scope: 'jobs',
      filters: filters,
      page: page,
      pageSize: pageSize,
      parse: JobModel.fromJson,
      idOf: (job) => job.id,
      fallback: () async => PostService.fetchJobs(filters: filters),
    );
  }

  // ── shared request / parse / degrade ───────────────────────────────────────

  static Future<FeedResult<T>> _fetch<T>({
    required String? userId,
    required double? latitude,
    required double? longitude,
    required String scope,
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

      final response = await http.get(uri).timeout(_timeout);
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
    required String scope,
    required PostFilters? filters,
    required int page,
    required int? pageSize,
  }) {
    // The viewer's UTC offset drives the time-of-day signal. Without it the
    // server would rank a Nairobi morning as though it were the middle of the
    // night, because the server's timezone is an accident of hosting.
    final tzOffset = DateTime.now().timeZoneOffset.inMinutes;

    return {
      'scope': scope,
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
    );
  }

  /// Map the tab scope onto the `type` column filter the old query expects.
  static PostFilters _withScopeType(PostFilters? filters, String scope) {
    final type = switch (scope) {
      'requests' => 'request',
      'offers' => 'offer',
      'jobs' => 'job',
      _ => null,
    };
    return PostFilters(
      searchQuery: filters?.searchQuery,
      categories: filters?.categories,
      city: filters?.city,
      area: filters?.area,
      type: type,
      urgency: filters?.urgency,
      minPrice: filters?.minPrice,
      maxPrice: filters?.maxPrice,
      difficulty: filters?.difficulty,
      limit: filters?.limit ?? 50,
      offset: filters?.offset ?? 0,
    );
  }
}
