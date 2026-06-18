import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import 'reputation_service.dart';

class ReviewException implements Exception {
  final String message;
  final int? statusCode;
  ReviewException(this.message, {this.statusCode});
  @override
  String toString() => 'ReviewException: $message';
}

/// Whether the current user may review a given job (drives the lifecycle button).
class ReviewEligibility {
  final bool canReview;
  final bool alreadyReviewed;
  final String? reviewId;
  final String? providerId;
  final String? reason;

  const ReviewEligibility({
    required this.canReview,
    required this.alreadyReviewed,
    required this.reviewId,
    required this.providerId,
    required this.reason,
  });

  static const none = ReviewEligibility(
    canReview: false,
    alreadyReviewed: false,
    reviewId: null,
    providerId: null,
    reason: null,
  );

  factory ReviewEligibility.fromJson(Map<String, dynamic> j) => ReviewEligibility(
        canReview: j['can_review'] as bool? ?? false,
        alreadyReviewed: j['already_reviewed'] as bool? ?? false,
        reviewId: j['review_id'] as String?,
        providerId: j['provider_id'] as String?,
        reason: j['reason'] as String?,
      );
}

/// Backend-mediated review submission engine (Phase 3.2D). No direct DB writes.
class ReviewService {
  static const Duration _timeout = Duration(seconds: 20);

  /// Eligibility for the lifecycle "Leave Review" button.
  static Future<ReviewEligibility> checkEligibility({
    required String postId,
    required String userId,
  }) async {
    if (postId.isEmpty || userId.isEmpty) return ReviewEligibility.none;
    try {
      final uri = Uri.parse(
        '${ApiConfig.baseUrl}/reviews/eligibility/$postId?user_id=${Uri.encodeComponent(userId)}',
      );
      final res = await http.get(uri).timeout(_timeout);
      if (res.statusCode == 200) {
        return ReviewEligibility.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('[REVIEW] checkEligibility error: $e');
    }
    return ReviewEligibility.none;
  }

  /// Submit a review. Returns the new review id. Throws [ReviewException] on
  /// failure (e.g. already reviewed, ineligible). Invalidates the provider's
  /// cached reputation so trust UI refreshes.
  static Future<String> submit({
    required String postId,
    required String clientId,
    required int rating,
    String? comment,
  }) async {
    final res = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/reviews'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'post_id': postId,
            'client_id': clientId,
            'rating': rating,
            if (comment != null && comment.trim().isNotEmpty) 'comment': comment.trim(),
          }),
        )
        .timeout(_timeout);

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode == 200 || res.statusCode == 201) {
      final providerId = json['provider_id'] as String?;
      if (providerId != null && providerId.isNotEmpty) {
        ReputationService.invalidate(providerId);
      }
      return json['review_id'] as String? ?? '';
    }
    throw ReviewException(_extractMessage(json), statusCode: res.statusCode);
  }

  static String _extractMessage(Map<String, dynamic> json) {
    final msg = json['message'];
    if (msg is List) return msg.join('; ');
    if (msg is String) return msg;
    return 'Could not submit your review. Please try again.';
  }
}
