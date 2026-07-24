import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../models/promotion_models.dart';

class PromotionException implements Exception {
  final String message;
  final int? statusCode;
  PromotionException(this.message, {this.statusCode});
  @override
  String toString() => 'PromotionException: $message';
}

/// Backend client for "Promote Business" (JobsService pattern: static methods,
/// asserted user_id, 30 s timeout, NestJS message extraction).
///
/// Serving calls (`fetchSlots`, `trackEvents`) are deliberately forgiving —
/// the feed must render organically even when the promotion backend is cold
/// or down, so they swallow errors and return empty/void.
class PromotionService {
  static const Duration _timeout = Duration(seconds: 30);

  /// Slots are feed-decoration: give up fast so a cold backend never makes
  /// the discover feed feel slow.
  static const Duration _servingTimeout = Duration(seconds: 6);

  static Map<String, String> get _jsonHeaders => {'Content-Type': 'application/json'};

  // ── Serving (public) ────────────────────────────────────────────────────────

  /// Sponsored slots for a placement. NEVER throws — an unreachable promotion
  /// engine simply renders an unsponsored feed.
  static Future<SlotsResult> fetchSlots({
    required String placement, // discover | search | category | nearby
    String? category,
    String? query,
    double? lat,
    double? lng,
  }) async {
    try {
      final params = <String, String>{
        'placement': placement,
        if (category != null && category.isNotEmpty) 'category': category,
        if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
        if (lat != null) 'lat': lat.toString(),
        if (lng != null) 'lng': lng.toString(),
      };
      final uri = Uri.parse('${ApiConfig.baseUrl}/promotions/slots')
          .replace(queryParameters: params);
      final response = await http.get(uri).timeout(_servingTimeout);
      if (response.statusCode != 200) return SlotsResult.empty;
      return SlotsResult.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[PROMO] fetchSlots failed (feed stays organic): $e');
      return SlotsResult.empty;
    }
  }

  /// Batched analytics events (impressions/clicks/taps). Fire-and-forget:
  /// never throws, never blocks UI.
  static Future<void> trackEvents(List<Map<String, dynamic>> events) async {
    if (events.isEmpty) return;
    try {
      await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/promotions/events'),
            headers: _jsonHeaders,
            body: jsonEncode({'events': events}),
          )
          .timeout(_servingTimeout);
    } catch (e) {
      debugPrint('[PROMO] trackEvents failed (dropped batch): $e');
    }
  }

  // ── Packages ────────────────────────────────────────────────────────────────

  static Future<List<PromotionPackage>> fetchPackages() async {
    final response = await http
        .get(Uri.parse('${ApiConfig.baseUrl}/promotions/packages'))
        .timeout(_timeout);
    if (response.statusCode == 200) {
      final list = jsonDecode(response.body) as List;
      return list
          .whereType<Map>()
          .map((e) => PromotionPackage.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    throw PromotionException(_message(response), statusCode: response.statusCode);
  }

  // ── Campaigns ───────────────────────────────────────────────────────────────

  static Future<PromotionCampaign> createCampaign({
    required String userId,
    required String postId,
    required String packageId,
  }) async {
    final response = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/promotions/campaigns'),
          headers: _jsonHeaders,
          body: jsonEncode({'user_id': userId, 'post_id': postId, 'package_id': packageId}),
        )
        .timeout(_timeout);
    if (response.statusCode == 200 || response.statusCode == 201) {
      return PromotionCampaign.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw PromotionException(_message(response), statusCode: response.statusCode);
  }

  static Future<List<PromotionCampaign>> fetchCampaigns(String userId) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/promotions/campaigns')
        .replace(queryParameters: {'user_id': userId});
    final response = await http.get(uri).timeout(_timeout);
    if (response.statusCode == 200) {
      final list = jsonDecode(response.body) as List;
      return list
          .whereType<Map>()
          .map((e) => PromotionCampaign.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    throw PromotionException(_message(response), statusCode: response.statusCode);
  }

  static Future<PromotionCampaign> _campaignAction(
    String campaignId,
    String action,
    String userId,
  ) async {
    final response = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/promotions/campaigns/$campaignId/$action'),
          headers: _jsonHeaders,
          body: jsonEncode({'user_id': userId}),
        )
        .timeout(_timeout);
    if (response.statusCode == 200 || response.statusCode == 201) {
      return PromotionCampaign.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw PromotionException(_message(response), statusCode: response.statusCode);
  }

  static Future<PromotionCampaign> pauseCampaign(String campaignId, String userId) =>
      _campaignAction(campaignId, 'pause', userId);

  static Future<PromotionCampaign> resumeCampaign(String campaignId, String userId) =>
      _campaignAction(campaignId, 'resume', userId);

  static Future<PromotionCampaign> cancelCampaign(String campaignId, String userId) =>
      _campaignAction(campaignId, 'cancel', userId);

  // ── Payment (M-Pesa STK) ────────────────────────────────────────────────────

  /// Sends the STK push. Returns the customer message to show while the
  /// prompt is on the payer's phone.
  static Future<String> payCampaign({
    required String campaignId,
    required String userId,
    String? phone,
  }) async {
    final response = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/promotions/campaigns/$campaignId/pay'),
          headers: _jsonHeaders,
          body: jsonEncode({
            'user_id': userId,
            if (phone != null && phone.isNotEmpty) 'phone': phone,
          }),
        )
        .timeout(_timeout);
    if (response.statusCode == 200 || response.statusCode == 201) {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      return json['message']?.toString() ?? 'Check your phone for the M-Pesa prompt.';
    }
    throw PromotionException(_message(response), statusCode: response.statusCode);
  }

  /// Poll target while waiting for the payer to enter their M-Pesa PIN.
  /// Returns campaign_status + payment_status (+ receipt/failure).
  static Future<Map<String, dynamic>> paymentStatus({
    required String campaignId,
    required String userId,
  }) async {
    final uri = Uri.parse(
      '${ApiConfig.baseUrl}/promotions/campaigns/$campaignId/payment-status',
    ).replace(queryParameters: {'user_id': userId});
    final response = await http.get(uri).timeout(_timeout);
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw PromotionException(_message(response), statusCode: response.statusCode);
  }

  // ── Analytics + history ─────────────────────────────────────────────────────

  static Future<CampaignAnalytics> fetchAnalytics({
    required String campaignId,
    required String userId,
  }) async {
    final uri = Uri.parse(
      '${ApiConfig.baseUrl}/promotions/campaigns/$campaignId/analytics',
    ).replace(queryParameters: {'user_id': userId});
    final response = await http.get(uri).timeout(_timeout);
    if (response.statusCode == 200) {
      return CampaignAnalytics.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw PromotionException(_message(response), statusCode: response.statusCode);
  }

  static Future<List<PromotionPaymentRecord>> fetchPayments(String userId) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/promotions/payments')
        .replace(queryParameters: {'user_id': userId});
    final response = await http.get(uri).timeout(_timeout);
    if (response.statusCode == 200) {
      final list = jsonDecode(response.body) as List;
      return list
          .whereType<Map>()
          .map((e) => PromotionPaymentRecord.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    throw PromotionException(_message(response), statusCode: response.statusCode);
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  static String _message(http.Response response) {
    try {
      final json = jsonDecode(response.body);
      if (json is Map) {
        final msg = json['message'];
        if (msg is List) return msg.join(', ');
        if (msg is String && msg.isNotEmpty) return msg;
      }
    } catch (_) {}
    debugPrint('[PromotionService] request failed status=${response.statusCode} body=${response.body}');
    if (response.statusCode >= 500) {
      return "We're having trouble on our end. Please try again shortly.";
    }
    return 'Something went wrong. Please try again.';
  }
}
