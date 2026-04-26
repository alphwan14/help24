import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

class ProviderServiceException implements Exception {
  final String message;
  final int? statusCode;
  ProviderServiceException(this.message, {this.statusCode});
  @override
  String toString() => 'ProviderServiceException: $message';
}

class ProviderService {
  static const _timeout = Duration(seconds: 30);

  /// Normalizes any Kenyan phone format to 254XXXXXXXXX (12 digits).
  /// Input can be 7XXXXXXXX (9 digits), 07XXXXXXXX (10), or +254XXXXXXXXX (13).
  static String normalizePhone(String raw) {
    final d = raw.replaceAll(RegExp(r'\D'), '');
    if (d.length == 9) return '254$d';
    if (d.length == 10 && d.startsWith('0')) return '254${d.substring(1)}';
    if (d.length == 12 && d.startsWith('254')) return d;
    if (d.length == 13 && d.startsWith('254')) return d.substring(1);
    return '254$d'; // best-effort
  }

  /// Converts a stored/Firebase phone (e.g. +254712345678) to the 9-digit
  /// display form (712345678) used in the phone input field.
  static String toDisplayPhone(String? stored) {
    if (stored == null || stored.isEmpty) return '';
    final d = stored.replaceAll(RegExp(r'\D'), '');
    if (d.length == 12 && d.startsWith('254')) return d.substring(3);
    if (d.length == 10 && d.startsWith('0')) return d.substring(1);
    if (d.length == 9) return d;
    return '';
  }

  /// Register a service provider. Payload matches RegisterProviderDto exactly.
  static Future<Map<String, dynamic>> registerProvider({
    required String name,
    required String phoneLogin,
    required String phonePayout,
    required List<String> services,
    required String location,
  }) async {
    const endpoint = '${ApiConfig.baseUrl}/providers/register';

    final body = {
      'name': name,
      'phone_login': normalizePhone(phoneLogin),
      'phone_payout': normalizePhone(phonePayout),
      'services': services,
      'location': location,
    };

    debugPrint('[ProviderService] POST $endpoint');

    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse(endpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } catch (e) {
      debugPrint('[ProviderService] network error: $e');
      throw ProviderServiceException('Network error — check your connection');
    }

    debugPrint('[ProviderService] ${response.statusCode}');

    if (response.statusCode == 200 || response.statusCode == 201) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }

    String errorMessage = 'Registration failed';
    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      errorMessage = (json['message'] as String?) ?? errorMessage;
    } catch (_) {}

    throw ProviderServiceException(errorMessage,
        statusCode: response.statusCode);
  }
}
