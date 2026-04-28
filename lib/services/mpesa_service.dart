import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

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
      transactionId: json['transactionId'] as String? ?? '',
      checkoutRequestId: json['checkoutRequestId'] as String? ?? '',
    );
  }
}

class PaymentStatusResult {
  final String status;
  final String? mpesaReceipt;
  final String? failureReason;

  const PaymentStatusResult({
    required this.status,
    this.mpesaReceipt,
    this.failureReason,
  });

  factory PaymentStatusResult.fromJson(Map<String, dynamic> json) {
    return PaymentStatusResult(
      status: json['status'] as String? ?? 'unknown',
      mpesaReceipt: json['mpesa_receipt'] as String?,
      failureReason: json['failure_reason'] as String?,
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
  /// The backend resolves buyer and provider phones from their stored profiles.
  /// [amount] is the service cost in KES (before platform fee).
  static Future<PaymentInitResult> initiatePayment({
    required String postId,
    required String buyerUserId,
    required double amount,
  }) async {
    final body = {
      'post_id': postId,
      'buyer_user_id': buyerUserId,
      'amount': amount,
    };

    debugPrint('[MpesaService] POST ${ApiConfig.initiatePayment}');

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

    debugPrint('[MpesaService] ${response.statusCode}');

    if (response.statusCode == 200 || response.statusCode == 201) {
      return PaymentInitResult.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    }

    String errorMessage = _sanitizePaymentError(response.statusCode, response.body);
    throw MpesaException(errorMessage, statusCode: response.statusCode);
  }

  static String _sanitizePaymentError(int statusCode, String body) {
    if (statusCode >= 500) {
      return 'Payment could not be initiated. Please try again.';
    }
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final raw = (json['message'] as String? ?? '').toLowerCase();
      // Pass through eligibility errors verbatim — they are user-meaningful.
      if (raw.contains('not available for payment') ||
          raw.contains('please log in')) {
        return json['message'] as String;
      }
      if (raw.contains('provider') && raw.contains('not')) {
        return 'Service provider not available for payment.';
      }
      if (raw.contains('phone') || raw.contains('format')) {
        return 'Payment could not be initiated. Please try again.';
      }
    } catch (_) {}
    if (statusCode == 401 || statusCode == 403) {
      return 'Please log in to continue.';
    }
    if (statusCode == 404) return 'Service not found. It may have been removed.';
    if (statusCode == 400) return 'Invalid payment request. Please try again.';
    return 'Payment could not be initiated. Please try again.';
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
