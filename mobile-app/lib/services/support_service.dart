import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

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
  /// [photoPaths] come from [uploadPhotos]; a message may be photos only.
  Future<SupportMessage> send({
    required String userId,
    required String body,
    required String clientId,
    List<String> photoPaths = const [],
  });

  /// Uploads up to 5 photos to the private bucket and returns their paths,
  /// ready for [send].
  Future<List<String>> uploadPhotos({required String userId, required List<SupportPhoto> photos});

  /// The member is looking at the thread: answers so far count as read.
  Future<void> markRead(String userId);
}

class SupportService implements SupportApi {
  SupportService._();
  static final SupportService instance = SupportService._();

  static const Duration _timeout = Duration(seconds: 30);
  static const Duration _uploadTimeout = Duration(seconds: 90);
  static const String _bucket = 'support-attachments';

  @override
  Future<SupportThread> thread(String userId) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/support/app/thread?user_id=${Uri.encodeComponent(userId)}');
    final res = await api.get(uri).timeout(_timeout);
    if (res.statusCode == 200) return SupportThread.fromJson(_json(res.body));
    throw SupportException(_message(res.body), statusCode: res.statusCode);
  }

  @override
  Future<SupportMessage> send({
    required String userId,
    required String body,
    required String clientId,
    List<String> photoPaths = const [],
  }) async {
    final res = await api
        .post(
          Uri.parse('${ApiConfig.baseUrl}/support/app/messages'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'user_id': userId,
            'body': body,
            'client_id': clientId,
            if (photoPaths.isNotEmpty) 'attachments': photoPaths,
          }),
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

  @override
  Future<List<String>> uploadPhotos({required String userId, required List<SupportPhoto> photos}) async {
    if (photos.isEmpty) return const [];
    // 1. Signed upload links from the backend, under this member's own prefix.
    final res = await api
        .post(
          Uri.parse('${ApiConfig.baseUrl}/support/app/attachments'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'user_id': userId,
            'files': [for (final p in photos) {'content_type': p.mime}],
          }),
        )
        .timeout(_timeout);
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw SupportException(_message(res.body), statusCode: res.statusCode);
    }
    final grants = _json(res.body)['files'];
    if (grants is! List || grants.length != photos.length) {
      throw SupportException('Upload could not be prepared');
    }
    // 2. The bytes go straight to the private bucket with each link.
    final storage = Supabase.instance.client.storage.from(_bucket);
    final paths = <String>[];
    for (var i = 0; i < photos.length; i++) {
      final grant = grants[i] as Map<String, dynamic>;
      final path = grant['path'] as String;
      await storage
          .uploadBinaryToSignedUrl(
            path,
            grant['token'] as String,
            photos[i].bytes,
            FileOptions(contentType: photos[i].mime, upsert: false),
          )
          .timeout(_uploadTimeout);
      paths.add(path);
    }
    return paths;
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
