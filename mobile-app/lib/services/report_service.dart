import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions, Supabase;

import '../config/api_config.dart';
import '../models/moderation.dart';
import 'api_client.dart';

/// A report the server refused, in words the sheet can show as written.
class ReportException implements Exception {
  ReportException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final String? code;

  @override
  String toString() => 'ReportException($statusCode ${code ?? ''}): $message';
}

/// A screenshot the reporter attached (bytes + type), before upload.
@immutable
class ReportAttachment {
  const ReportAttachment({required this.bytes, required this.mimeType, required this.name});

  final Uint8List bytes;
  final String mimeType;
  final String name;
}

enum ReportOutcomeKind {
  /// Filed. The reference is what support can look it up by.
  received,

  /// The same person already has an open report about the same thing. Not an
  /// error from the reporter's point of view: their concern is already with us.
  alreadyReported,
}

@immutable
class ReportOutcome {
  const ReportOutcome(this.kind, this.reference);
  final ReportOutcomeKind kind;
  final String? reference;
}

/// Files reports through the backend.
///
/// WHY NOT A DIRECT INSERT ANY MORE
/// --------------------------------
/// This used to insert into `user_reports` straight from the app, naming the
/// reporter in the row. `POST /reports` is @AuthCritical: the reporter is the
/// VERIFIED caller, bound from the Firebase token, so a report can no longer be
/// filed in someone else's name. Who is being reported, and every triage field,
/// is derived server-side from the target (migration 114) — this client sends
/// only what was reported and why.
class ReportService {
  ReportService._();

  static const Duration _timeout = Duration(seconds: 30);
  static const String _bucket = 'dispute-evidence';

  /// Mirrors MAX_REPORT_EVIDENCE / REPORT_EVIDENCE_MIME / MAX_EVIDENCE_BYTES in
  /// backend/src/moderation/moderation.constants.ts.
  static const int maxAttachments = 3;
  static const int maxAttachmentBytes = 10 * 1024 * 1024;
  static const Set<String> allowedMimeTypes = {'image/jpeg', 'image/png', 'image/webp'};
  static const int maxDetails = 1000;

  static Map<String, String> get _json => const {'Content-Type': 'application/json'};

  /// Upload [attachments] (if any), then file the report.
  static Future<ReportOutcome> submit({
    required ReportTarget target,
    required ReportCategory category,
    String details = '',
    List<ReportAttachment> attachments = const [],
  }) async {
    if (!target.categories.contains(category)) {
      throw ReportException('Choose one of the listed reasons.');
    }
    final evidence = attachments.isEmpty ? const <Map<String, Object>>[] : await _upload(attachments);

    final trimmed = details.trim();
    final body = <String, Object>{
      'target_type': target.type.wire,
      'target_id': target.id,
      'category': category.wire,
      if (trimmed.isNotEmpty) 'details': trimmed.length > maxDetails ? trimmed.substring(0, maxDetails) : trimmed,
      if (target.type == ReportTargetType.user && (target.chatId?.isNotEmpty ?? false)) 'chat_id': target.chatId!,
      if (target.type == ReportTargetType.user && (target.postId?.isNotEmpty ?? false)) 'post_id': target.postId!,
      if (evidence.isNotEmpty) 'evidence': evidence,
    };

    final res = await api
        .post(Uri.parse('${ApiConfig.baseUrl}/reports'), headers: _json, body: jsonEncode(body))
        .timeout(_timeout);

    if (res.statusCode == 200 || res.statusCode == 201) {
      final json = _decode(res.body);
      if (json['status'] == 'already_reported') {
        return const ReportOutcome(ReportOutcomeKind.alreadyReported, null);
      }
      return ReportOutcome(ReportOutcomeKind.received, json['reference']?.toString());
    }
    throw _refusal(res.statusCode, _decode(res.body));
  }

  /// Signed upload URLs from the backend, bytes straight to the private
  /// bucket — the same two-step flow as dispute evidence. Paths come back
  /// under `reports/<my uid>/`, and the database refuses any other prefix.
  static Future<List<Map<String, Object>>> _upload(List<ReportAttachment> files) async {
    if (files.length > maxAttachments) {
      throw ReportException('You can attach up to $maxAttachments screenshots.');
    }
    for (final f in files) {
      if (!allowedMimeTypes.contains(f.mimeType)) {
        throw ReportException('Screenshots must be JPG, PNG or WEBP images.');
      }
      if (f.bytes.length > maxAttachmentBytes) {
        throw ReportException('Each screenshot must be under 10 MB.');
      }
    }

    final grantRes = await api
        .post(
          Uri.parse('${ApiConfig.baseUrl}/reports/evidence/upload-url'),
          headers: _json,
          body: jsonEncode({
            'files': [for (final f in files) {'content_type': f.mimeType, 'file_name': f.name}],
          }),
        )
        .timeout(_timeout);
    if (grantRes.statusCode != 200 && grantRes.statusCode != 201) {
      throw _refusal(grantRes.statusCode, _decode(grantRes.body));
    }
    final grants = (_decode(grantRes.body)['files'] as List?)?.whereType<Map>().toList() ?? const [];
    if (grants.length != files.length) {
      throw ReportException("We couldn't prepare your screenshots. Please try again.");
    }

    final storage = Supabase.instance.client.storage.from(_bucket);
    final items = <Map<String, Object>>[];
    for (var i = 0; i < files.length; i++) {
      final path = grants[i]['path']?.toString() ?? '';
      final token = grants[i]['token']?.toString() ?? '';
      if (path.isEmpty || token.isEmpty) {
        throw ReportException("We couldn't prepare your screenshots. Please try again.");
      }
      try {
        await storage.uploadBinaryToSignedUrl(
          path,
          token,
          files[i].bytes,
          FileOptions(contentType: files[i].mimeType, upsert: false),
        );
      } catch (e) {
        debugPrint('[REPORT] screenshot upload failed: $e');
        throw ReportException("A screenshot didn't upload. Check your connection and try again.");
      }
      items.add({'path': path, 'mime_type': files[i].mimeType, 'size_bytes': files[i].bytes.length});
    }
    return items;
  }

  /// The server's refusal, mapped to copy that tells the reporter what to do.
  /// Codes come from backend/src/moderation/moderation-errors.ts.
  static ReportException _refusal(int status, Map<String, dynamic> body) {
    final code = body['code']?.toString();
    final message = switch (code) {
      'REPORT_SELF' => "You can't report yourself.",
      'REPORT_LIMIT' => "You've sent a lot of reports today. Please try again tomorrow.",
      'REPORT_NOT_PARTICIPANT' => "You can only report things you were part of.",
      'REPORT_INVALID_CATEGORY' => 'Choose one of the listed reasons.',
      'REPORT_INVALID_TARGET' => "This is no longer available to report. If it's still a problem, contact Help24.",
      _ => switch (status) {
          401 => 'Please sign in again to send a report.',
          429 => "You've sent a lot of reports recently. Please wait a moment and try again.",
          _ => "Your report didn't send. Please try again.",
        },
    };
    return ReportException(message, statusCode: status, code: code);
  }

  static Map<String, dynamic> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }
}
