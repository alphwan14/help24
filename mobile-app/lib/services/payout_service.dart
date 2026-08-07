import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/payout_models.dart';
import 'api_client.dart';

/// Thrown for every non-2xx from the payout-destination API.
///
/// `statusCode` lets ErrorMapper pick the right family (429 → "slow down").
/// `code` is the backend's structured OTP outcome — branch on it, never on
/// message text: OTP_INVALID | OTP_EXPIRED | OTP_LOCKED | OTP_NOT_FOUND |
/// OTP_COOLDOWN.
class PayoutException implements Exception {
  final String message;
  final int? statusCode;
  final String? code;
  final int? attemptsRemaining;
  final int? retryAfterSeconds;

  PayoutException(
    this.message, {
    this.statusCode,
    this.code,
    this.attemptsRemaining,
    this.retryAfterSeconds,
  });

  /// The whole feature answers 503 until the backend flag is on.
  bool get featureUnavailable => statusCode == 503;

  @override
  String toString() => message;
}

/// Client for `/payout-destinations` — the provider-side flow that decides
/// where M-Pesa payouts go. All calls are authenticated; `user_id` is
/// overwritten server-side with the verified uid, so passing it is a formality
/// the API contract requires, not a trust decision.
class PayoutService {
  PayoutService._();

  static const Duration _timeout = Duration(seconds: 30);
  static Map<String, String> get _jsonHeaders => {'Content-Type': 'application/json'};

  static Uri _uri(String path) => Uri.parse('${ApiConfig.baseUrl}$path');

  static Future<List<PayoutDestination>> listDestinations(String uid) async {
    final response = await api
        .get(_uri('/payout-destinations?user_id=$uid'))
        .timeout(_timeout);
    final body = _decode(response);
    final list = body['destinations'];
    if (list is! List) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(PayoutDestination.fromJson)
        .toList();
  }

  /// Adds a number and issues its verification code in one call.
  static Future<PayoutDestination> addDestination(String uid, String msisdn) async {
    final response = await api
        .post(_uri('/payout-destinations'),
            headers: _jsonHeaders,
            body: jsonEncode({'user_id': uid, 'msisdn': msisdn}))
        .timeout(_timeout);
    final body = _decode(response, expected: 201);
    return PayoutDestination.fromJson(
        (body['destination'] as Map<String, dynamic>?) ?? const {});
  }

  /// Resend. The backend enforces a 60s cooldown (429 + retryAfterSeconds).
  static Future<PayoutChallenge> requestChallenge(
      String uid, String destinationId) async {
    final response = await api
        .post(_uri('/payout-destinations/$destinationId/challenge'),
            headers: _jsonHeaders, body: jsonEncode({'user_id': uid}))
        .timeout(_timeout);
    final body = _decode(response);
    return PayoutChallenge.fromJson(
        (body['verification'] as Map<String, dynamic>?) ?? const {});
  }

  /// Returns the now-active destination, or throws a PayoutException whose
  /// `code` names the failure state.
  static Future<PayoutDestination> verify(
    String uid,
    String destinationId,
    String code, {
    bool makeDefault = true,
  }) async {
    final response = await api
        .post(_uri('/payout-destinations/$destinationId/verify'),
            headers: _jsonHeaders,
            body: jsonEncode({
              'user_id': uid,
              'code': code,
              'make_default': makeDefault,
            }))
        .timeout(_timeout);
    final body = _decode(response);
    return PayoutDestination.fromJson(
        (body['destination'] as Map<String, dynamic>?) ?? const {});
  }

  static Future<PayoutDestination> setDefault(
      String uid, String destinationId) async {
    final response = await api
        .post(_uri('/payout-destinations/$destinationId/default'),
            headers: _jsonHeaders, body: jsonEncode({'user_id': uid}))
        .timeout(_timeout);
    final body = _decode(response);
    return PayoutDestination.fromJson(
        (body['destination'] as Map<String, dynamic>?) ?? const {});
  }

  static Future<void> retire(
      String uid, String destinationId, String reason) async {
    final response = await api
        .post(_uri('/payout-destinations/$destinationId/retire'),
            headers: _jsonHeaders,
            body: jsonEncode({'user_id': uid, 'reason': reason}))
        .timeout(_timeout);
    _decode(response);
  }

  // ── shared response handling ──────────────────────────────────────────────

  static Map<String, dynamic> _decode(http.Response response, {int expected = 200}) {
    if (response.statusCode == expected ||
        (response.statusCode >= 200 && response.statusCode < 300)) {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : const {};
    }
    throw _failure(response);
  }

  static PayoutException _failure(http.Response response) {
    String message = response.statusCode >= 500
        ? "We're having trouble on our end. Please try again shortly."
        : 'Something went wrong. Please try again.';
    String? code;
    int? attemptsRemaining;
    int? retryAfterSeconds;
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        final raw = body['message'];
        if (raw is String && raw.isNotEmpty) message = raw;
        if (raw is List && raw.isNotEmpty) message = raw.join(', ');
        if (body['code'] is String) code = body['code'] as String;
        if (body['attemptsRemaining'] is num) {
          attemptsRemaining = (body['attemptsRemaining'] as num).toInt();
        }
        if (body['retryAfterSeconds'] is num) {
          retryAfterSeconds = (body['retryAfterSeconds'] as num).toInt();
        }
      }
    } catch (_) {
      // Non-JSON body: keep the status-based fallback.
    }
    return PayoutException(
      message,
      statusCode: response.statusCode,
      code: code,
      attemptsRemaining: attemptsRemaining,
      retryAfterSeconds: retryAfterSeconds,
    );
  }
}
