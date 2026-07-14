import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../models/provider_reputation.dart';

/// Backend-mediated reputation access. The ONLY way the app obtains provider
/// trust data — there are no direct Supabase reads.
///
/// Includes an in-memory cache + in-flight dedup so a feed / applicant list of
/// N cards makes at most one request per distinct provider id.
class ReputationService {
  static const Duration _timeout = Duration(seconds: 15);

  /// Cache TTL: long enough that a feed of N cards never refetches while
  /// scrolling, short enough that your OWN profile reflects a new review or
  /// approved job without an app restart (the old cache lived forever).
  static const Duration _cacheTtl = Duration(minutes: 3);

  static final Map<String, ({ProviderReputation rep, DateTime at})> _cache = {};
  static final Map<String, Future<ProviderReputation?>> _inflight = {};

  /// Reputation summary for a provider. Returns null on error (callers render an
  /// empty/hidden state — never a fabricated value).
  static Future<ProviderReputation?> getReputation(String providerId) {
    if (providerId.isEmpty) return Future.value(null);

    final cached = _cache[providerId];
    if (cached != null && DateTime.now().difference(cached.at) < _cacheTtl) {
      return Future.value(cached.rep);
    }

    final existing = _inflight[providerId];
    if (existing != null) return existing;

    final future = _fetchReputation(providerId);
    _inflight[providerId] = future;
    return future.whenComplete(() => _inflight.remove(providerId));
  }

  static Future<ProviderReputation?> _fetchReputation(String providerId) async {
    try {
      final res = await http
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
        return rep;
      }
      debugPrint('[REPUTATION] getReputation $providerId -> ${res.statusCode}');
    } catch (e) {
      debugPrint('[REPUTATION] getReputation $providerId error: $e');
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
      final res = await http.get(uri).timeout(_timeout);
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
  static void invalidate(String providerId) => _cache.remove(providerId);
}
