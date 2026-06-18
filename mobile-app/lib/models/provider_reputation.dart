/// Typed response of GET /reputation/:providerId. The ONLY source of provider
/// trust data on the client — never read users.average_rating / total_reviews /
/// completed_jobs_count directly.
class ProviderReputation {
  final String providerId;
  final double averageRating;
  final double bayesianRating;
  final int totalReviews;
  final int completedJobs;
  final int disputedJobs;
  final int openDisputes;
  final double completionRate; // 0..1
  final double disputeRate; // 0..1
  final int repeatClients;
  final String tier;
  final String? memberSince; // ISO timestamp
  final String? lastActiveAt;

  const ProviderReputation({
    required this.providerId,
    required this.averageRating,
    required this.bayesianRating,
    required this.totalReviews,
    required this.completedJobs,
    required this.disputedJobs,
    required this.openDisputes,
    required this.completionRate,
    required this.disputeRate,
    required this.repeatClients,
    required this.tier,
    required this.memberSince,
    required this.lastActiveAt,
  });

  bool get hasReviews => totalReviews > 0;
  bool get isNew => tier == 'new_provider';

  /// Human label for the derived tier.
  String get tierLabel {
    switch (tier) {
      case 'trusted_professional':
        return 'Trusted Professional';
      case 'highly_recommended':
        return 'Highly Recommended';
      case 'top_rated':
        return 'Top Rated';
      case 'rising_provider':
        return 'Rising Provider';
      case 'new_provider':
      default:
        return 'New Provider';
    }
  }

  /// Completion rate as a whole-number percentage (e.g. 0.98 -> 98).
  int get completionPercent => (completionRate * 100).round();
  int get disputePercent => (disputeRate * 100).round();

  /// Member-since year (e.g. "2026"), or null.
  String? get memberSinceYear {
    if (memberSince == null) return null;
    final dt = DateTime.tryParse(memberSince!);
    return dt == null ? null : dt.year.toString();
  }

  static double _toDouble(dynamic v) => (v is num) ? v.toDouble() : 0.0;
  static int _toInt(dynamic v) => (v is num) ? v.toInt() : 0;

  factory ProviderReputation.fromJson(Map<String, dynamic> j) => ProviderReputation(
        providerId: j['provider_id'] as String? ?? '',
        averageRating: _toDouble(j['average_rating']),
        bayesianRating: _toDouble(j['bayesian_rating']),
        totalReviews: _toInt(j['total_reviews']),
        completedJobs: _toInt(j['completed_jobs']),
        disputedJobs: _toInt(j['disputed_jobs']),
        openDisputes: _toInt(j['open_disputes']),
        completionRate: _toDouble(j['completion_rate']),
        disputeRate: _toDouble(j['dispute_rate']),
        repeatClients: _toInt(j['repeat_clients']),
        tier: j['tier'] as String? ?? 'new_provider',
        memberSince: j['member_since'] as String?,
        lastActiveAt: j['last_active_at'] as String?,
      );
}

/// One review row from GET /reviews/provider/:providerId.
class ProviderReview {
  final String id;
  final String postId;
  final int rating;
  final String? comment;
  final bool fromDisputedJob;
  final String? providerReply;
  final String? createdAt;

  const ProviderReview({
    required this.id,
    required this.postId,
    required this.rating,
    required this.comment,
    required this.fromDisputedJob,
    required this.providerReply,
    required this.createdAt,
  });

  factory ProviderReview.fromJson(Map<String, dynamic> j) => ProviderReview(
        id: j['id'] as String? ?? '',
        postId: j['post_id'] as String? ?? '',
        rating: (j['rating'] is num) ? (j['rating'] as num).toInt() : 0,
        comment: j['comment'] as String?,
        fromDisputedJob: j['from_disputed_job'] as bool? ?? false,
        providerReply: j['provider_reply'] as String?,
        createdAt: j['created_at'] as String?,
      );
}

/// One page of provider reviews (cursor-paginated).
class ProviderReviewsPage {
  final List<ProviderReview> reviews;
  final String? nextCursor;
  const ProviderReviewsPage({required this.reviews, required this.nextCursor});
}
