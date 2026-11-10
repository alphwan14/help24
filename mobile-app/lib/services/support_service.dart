import 'dart:convert';

// Backend calls go through the authenticated client: it attaches the Firebase
// ID token, and the backend binds `user_id` to it, so a member can only ever
// read and write their own conversation. See api_client.dart.
import 'api_client.dart';
import '../config/api_config.dart';
import '../models/support_thread.dart';

class SupportException implements Exception {
  final String message;
  final int? statusCode;
  SupportException(this.message, {this.statusCode});
  @override
  String toString() => 'SupportException: $message';
}

/// Message Help24: the member's conversation with Help24 (backend
/// /support/app/*). An interface so the screen can be tested without a network.
abstract class SupportApi {
  Future<SupportThread> thread(String userId);

  /// Sends one message. [clientId] makes a retry safe: the backend stores it once.
  Future<SupportMessage> send({required String userId, required String body, required String clientId});

  /// The member is looking at the thread: answers so far count as read.
  Future<void> markRead(String userId);
}

class SupportService implements SupportApi {
  SupportService._();
  static final SupportService instance = SupportService._();

  static const Duration _timeout = Duration(seconds: 30);

  @override
  Future<SupportThread> thread(String userId) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/support/app/thread?user_id=${Uri.encodeComponent(userId)}');
    final res = await api.get(uri).timeout(_timeout);
    if (res.statusCode == 200) return SupportThread.fromJson(_json(res.body));
    throw SupportException(_message(res.body), statusCode: res.statusCode);
  }

  @override
  Future<SupportMessage> send({required String userId, required String body, required String clientId}) async {
    final res = await api
        .post(
          Uri.parse('${ApiConfig.baseUrl}/support/app/messages'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'user_id': userId, 'body': body, 'client_id': clientId}),
        )
        .timeout(_timeout);
    if (res.statusCode == 200 || res.statusCode == 201) {
      final message = _json(res.body)['message'];
      if (message is Map<String, dynamic>) return SupportMessage.fromJson(message);
    }
    throw SupportException(_message(res.body), statusCode: res.statusCode);
  }

  @override
  Future<void> markRead(String userId) async {
    final res = await api
        .post(
          Uri.parse('${ApiConfig.baseUrl}/support/app/read'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'user_id': userId}),
        )
        .timeout(_timeout);
    if (res.statusCode == 200 || res.statusCode == 201) return;
    throw SupportException(_message(res.body), statusCode: res.statusCode);
  }

  static Map<String, dynamic> _json(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  /// The server's message, for logs and the error mapper; never shown raw.
  static String _message(String body) {
    final m = _json(body)['message'];
    if (m is String) return m;
    if (m is List && m.isNotEmpty) return m.first.toString();
    return 'Request failed';
  }
}
