import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../utils/phone_utils.dart';

class MpesaException implements Exception {
  final String message;
  final int? statusCode;
  MpesaException(this.message, {this.statusCode});
  @override
  String toString() => 'MpesaException: $message';
}

class PaymentInitResult {
  final String message;
  final String transactionId;
  final String checkoutRequestId;

  const PaymentInitResult({
    required this.message,
    required this.transactionId,
    required this.checkoutRequestId,
  });

  factory PaymentInitResult.fromJson(Map<String, dynamic> json) {
    return PaymentInitResult(
      message: json['message'] as String? ?? '',
      transactionId: json['transaction_id'] as String? ?? '',
      checkoutRequestId: json['checkout_request_id'] as String? ?? '',
    );
  }
}

class PaymentStatusResult {
  final String status;
  final String? mpesaReceipt;
  final String? failureReason;
  /// Escrow holding status (locked | payout_pending | released | refunded), from
  /// the backend's joined escrow row. Lets clients read settlement state WITHOUT
  /// touching the RLS-locked escrow table directly (security: S2 lockdown).
  final String? escrowStatus;

  const PaymentStatusResult({
    required this.status,
    this.mpesaReceipt,
    this.failureReason,
    this.escrowStatus,
  });

  factory PaymentStatusResult.fromJson(Map<String, dynamic> json) {
    // PostgREST may return the embedded escrow as an object (to-one) or a
    // single-element array (to-many) depending on the detected relationship.
    final raw = json['escrow'];
    Map<String, dynamic>? escrow;
    if (raw is Map<String, dynamic>) {
      escrow = raw;
    } else if (raw is List && raw.isNotEmpty && raw.first is Map<String, dynamic>) {
      escrow = raw.first as Map<String, dynamic>;
    }
    return PaymentStatusResult(
      status: json['status'] as String? ?? 'unknown',
      mpesaReceipt: json['mpesa_receipt'] as String?,
      failureReason: json['failure_reason'] as String?,
      escrowStatus: escrow?['status'] as String?,
    );
  }

  bool get isPending => status == 'pending';
  bool get isPaid => status == 'paid';
  bool get isFailed => status == 'failed';
}

class MpesaService {
  static const Duration _timeout = Duration(seconds: 30);

  /// Initiate STK push.
  ///
  /// [buyerPhone] is validated client-side for early UX feedback but NOT sent
  /// to the backend — the server fetches the buyer's phone from the DB using
  /// [buyerUserId].
  static Future<PaymentInitResult> initiatePayment({
    required String postId,
    required String buyerUserId,
    required String buyerPhone,
  }) async {
    final normalized = normalizeKenyanNumber(buyerPhone);
    if (normalized == null) {
      throw MpesaException(
        'Invalid M-Pesa number "$buyerPhone". Update your profile with a valid 254XXXXXXXXX number.',
      );
    }

    final body = {
      'post_id': postId,
      'buyer_user_id': buyerUserId,
    };

    debugPrint('[MpesaService] POST ${ApiConfig.initiatePayment} post=$postId buyer=$buyerUserId');

    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse(ApiConfig.initiatePayment),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } catch (e) {
      debugPrint('[MpesaService] network error: $e');
      throw MpesaException('Network error — check your connection');
    }

    debugPrint('[MpesaService] status=${response.statusCode} body=${response.body}');

    if (response.statusCode == 200 || response.statusCode == 201) {
      return PaymentInitResult.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    }

    final errorMessage = _extractErrorMessage(response.statusCode, response.body);
    debugPrint('[MpesaService] error extracted: $errorMessage');
    throw MpesaException(errorMessage, statusCode: response.statusCode);
  }

  /// Extracts a user-friendly error string from a non-2xx backend response.
  /// Handles NestJS exception bodies, class-validator arrays, and raw text.
  static String _extractErrorMessage(int statusCode, String body) {
    debugPrint('[MpesaService] _extractErrorMessage status=$statusCode body=$body');
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final msg = json['message'];

      // class-validator returns an array of field-level messages.
      // Map them to a single readable string — hide internal field names.
      if (msg is List && msg.isNotEmpty) {
        final joined = msg.join(' | ');
        debugPrint('[MpesaService] class-validator array: $joined');
        // If any entry mentions phone, surface a clean message.
        final lower = joined.toLowerCase();
        if (lower.contains('phone') || lower.contains('buyer_phone')) {
          return 'Please add a valid M-Pesa number (254XXXXXXXXX) to your profile.';
        }
        return 'Unable to start payment. Check your details and try again.';
      }

      // Plain string message from BadRequestException / custom throw.
      if (msg is String && msg.isNotEmpty) return msg;
    } catch (_) {
      // Body wasn't JSON — return raw body if short enough.
      if (body.isNotEmpty && body.length < 300) return body;
    }

    // Fallback by status code.
    if (statusCode == 401 || statusCode == 403) return 'Please log in to continue.';
    if (statusCode == 404) return 'Service not found. It may have been removed.';
    if (statusCode == 409) return 'Payment has already been made for this service.';
    debugPrint('[MpesaService] start-payment failed status=$statusCode body=$body');
    if (statusCode >= 500) {
      return "We're having trouble reaching M-Pesa. Please try again shortly.";
    }
    return 'Payment could not be started. Please try again.';
  }

  /// Sandbox smoke-test — calls /mpesa/test-stk with the supplied [phone].
  /// Amount is fixed at 1 on the backend. Returns the raw response map.
  static Future<Map<String, dynamic>> testStk(String phone, {double amount = 1}) async {
    const url = '${ApiConfig.baseUrl}/mpesa/test-stk';
    debugPrint('[MpesaService] POST $url phone=$phone amount=$amount');
    try {
      final response = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'phone': phone, 'amount': amount}),
          )
          .timeout(_timeout);
      debugPrint('[MpesaService] test-stk status=${response.statusCode} body=${response.body}');
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// DEV/sandbox only — forces the pending transaction for [postId] to "paid".
  /// The backend blocks this in production (returns 400).
  static Future<Map<String, dynamic>> forceSuccess(String postId) async {
    const url = '${ApiConfig.baseUrl}/mpesa/dev/force-success';
    debugPrint('[MpesaService][DEV] POST $url postId=$postId');
    try {
      final response = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'post_id': postId}),
          )
          .timeout(_timeout);
      debugPrint('[MpesaService][DEV] force-success ${response.statusCode} ${response.body}');
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Poll payment status by post ID. Keep polling while status is "pending".
  static Future<PaymentStatusResult> pollPaymentStatus(String postId) async {
    final url = '${ApiConfig.paymentStatus}/$postId';
    debugPrint('[MpesaService] GET $url');

    final http.Response response;
    try {
      response = await http.get(Uri.parse(url)).timeout(_timeout);
    } catch (e) {
      debugPrint('[MpesaService] poll network error: $e');
      throw MpesaException('Network error — check your connection');
    }

    debugPrint('[MpesaService] poll ${response.statusCode}');

    if (response.statusCode == 200) {
      return PaymentStatusResult.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    }

    throw MpesaException('Could not fetch payment status',
        statusCode: response.statusCode);
  }
}
