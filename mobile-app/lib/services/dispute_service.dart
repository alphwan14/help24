import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/api_config.dart';
import '../models/dispute_thread.dart';

class DisputeException implements Exception {
  final String message;
  final int? statusCode;
  DisputeException(this.message, {this.statusCode});
  @override
  String toString() => 'DisputeException: $message';
}

/// A file the user picked for upload (bytes + metadata), source-agnostic
/// (image_picker or file_picker both reduce to this).
class EvidenceUpload {
  final String fileName;
  final String mimeType;
  final Uint8List bytes;
  const EvidenceUpload({required this.fileName, required this.mimeType, required this.bytes});
  int get sizeBytes => bytes.length;
}

/// Participant-facing dispute communication client. All access is mediated by the
/// backend (service-role); the only direct Storage call is uploading bytes to a
/// backend-issued signed URL for the private dispute-evidence bucket.
class DisputeService {
  static const Duration _timeout = Duration(seconds: 30);
  static const String _bucket = 'dispute-evidence';

  /// Allowed by the backend + bucket: jpg/jpeg/png/webp/pdf, ≤10MB, ≤10 files.
  static const int maxFiles = 10;
  static const int maxFileBytes = 10 * 1024 * 1024;
  static const Set<String> allowedMimeTypes = {
    'image/jpeg',
    'image/png',
    'image/webp',
    'application/pdf',
  };

  /// GET /disputes/:id/thread?user_id= — participant case view.
  static Future<DisputeThread> getThread({
    required String disputeId,
    required String userId,
  }) async {
    final uri = Uri.parse(
      '${ApiConfig.baseUrl}/disputes/$disputeId/thread?user_id=${Uri.encodeComponent(userId)}',
    );
    final res = await http.get(uri).timeout(_timeout);
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode == 200) return DisputeThread.fromJson(json);
    throw DisputeException(_msg(json), statusCode: res.statusCode);
  }

  /// POST /disputes/:id/reply — participant posts a text message.
  static Future<void> reply({
    required String disputeId,
    required String userId,
    required String message,
  }) async {
    final res = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/disputes/$disputeId/reply'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'user_id': userId, 'message': message}),
        )
        .timeout(_timeout);
    if (res.statusCode == 200 || res.statusCode == 201) return;
    throw DisputeException(_msg(_safe(res.body)), statusCode: res.statusCode);
  }

  /// Full evidence flow: validate → request signed upload URLs → push bytes to
  /// Storage → register the objects as evidence. Returns when the case is updated.
  static Future<void> uploadEvidence({
    required String disputeId,
    required String userId,
    required List<EvidenceUpload> files,
  }) async {
    if (files.isEmpty) throw DisputeException('Select at least one file.');
    if (files.length > maxFiles) {
      throw DisputeException('You can attach at most $maxFiles files at once.');
    }
    for (final f in files) {
      if (!allowedMimeTypes.contains(f.mimeType)) {
        throw DisputeException('Unsupported file "${f.fileName}". Use JPG, PNG, WEBP or PDF.');
      }
      if (f.sizeBytes > maxFileBytes) {
        throw DisputeException('"${f.fileName}" is larger than 10MB.');
      }
    }

    // 1. Ask the backend for signed upload URLs.
    final urlRes = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/disputes/$disputeId/evidence/upload-url'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'user_id': userId,
            'files': files.map((f) => {'file_name': f.fileName, 'content_type': f.mimeType}).toList(),
          }),
        )
        .timeout(_timeout);
    if (urlRes.statusCode != 200 && urlRes.statusCode != 201) {
      throw DisputeException(_msg(_safe(urlRes.body)), statusCode: urlRes.statusCode);
    }
    final urlJson = jsonDecode(urlRes.body) as Map<String, dynamic>;
    final grants = (urlJson['files'] as List<dynamic>).cast<Map<String, dynamic>>();
    if (grants.length != files.length) {
      throw DisputeException('Upload could not be prepared. Please try again.');
    }

    // 2. Push bytes to the private bucket via each signed URL.
    final storage = Supabase.instance.client.storage.from(_bucket);
    final items = <Map<String, dynamic>>[];
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      final path = grants[i]['path'] as String;
      final token = grants[i]['token'] as String;
      try {
        await storage.uploadBinaryToSignedUrl(
          path,
          token,
          f.bytes,
          FileOptions(contentType: f.mimeType, upsert: false),
        );
      } catch (e) {
        debugPrint('[DisputeService] upload failed for ${f.fileName}: $e');
        throw DisputeException('Could not upload "${f.fileName}". Check your connection and retry.');
      }
      items.add({
        'path': path,
        'file_name': f.fileName,
        'mime_type': f.mimeType,
        'size_bytes': f.sizeBytes,
      });
    }

    // 3. Register the uploaded objects as evidence on the case.
    final submitRes = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/disputes/$disputeId/evidence/submit'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'user_id': userId, 'items': items}),
        )
        .timeout(_timeout);
    if (submitRes.statusCode == 200 || submitRes.statusCode == 201) return;
    throw DisputeException(_msg(_safe(submitRes.body)), statusCode: submitRes.statusCode);
  }

  static Map<String, dynamic> _safe(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }

  static String _msg(Map<String, dynamic> json) {
    final msg = json['message'];
    if (msg is List) return msg.join('; ');
    if (msg is String) return msg;
    return 'Something went wrong. Please try again.';
  }
}
