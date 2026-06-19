import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../models/job_lifecycle.dart';

class JobsException implements Exception {
  final String message;
  final int? statusCode;
  JobsException(this.message, {this.statusCode});
  @override
  String toString() => 'JobsException: $message';
}

class JobCompletionStatus {
  final String? id;
  final String? status;
  final String? providerNote;
  final DateTime? createdAt;

  const JobCompletionStatus({
    this.id,
    this.status,
    this.providerNote,
    this.createdAt,
  });

  bool get isPendingApproval => status == 'pending_approval';
  bool get isApproved => status == 'approved';
  bool get isDisputed => status == 'disputed';

  factory JobCompletionStatus.fromJson(Map<String, dynamic> json) {
    return JobCompletionStatus(
      id: json['id'] as String?,
      status: json['status'] as String?,
      providerNote: json['provider_note'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
    );
  }
}

class JobsService {
  static const Duration _timeout = Duration(seconds: 30);

  /// Provider marks the job as done.
  static Future<String> markComplete({
    required String postId,
    required String providerUserId,
    String? providerNote,
  }) async {
    final body = {
      'post_id': postId,
      'provider_user_id': providerUserId,
      if (providerNote != null && providerNote.isNotEmpty)
        'provider_note': providerNote,
    };

    final response = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/jobs/mark-complete'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(_timeout);

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200 || response.statusCode == 201) {
      return json['completion_id'] as String? ?? '';
    }
    final msg = _extractMessage(json);
    throw JobsException(msg, statusCode: response.statusCode);
  }

  /// Client approves the completion — triggers payout.
  static Future<void> approve({
    required String postId,
    required String clientUserId,
  }) async {
    final response = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/jobs/approve'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'post_id': postId, 'client_user_id': clientUserId}),
        )
        .timeout(_timeout);

    if (response.statusCode == 200 || response.statusCode == 201) return;
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    throw JobsException(_extractMessage(json), statusCode: response.statusCode);
  }

  /// Raise a dispute through the arbitration centre (POST /disputes/create).
  ///
  /// This replaces the legacy POST /jobs/dispute path. Routing through the
  /// arbitration service activates dedupe (one open case per job), anti-spam
  /// rate limiting, post-payout guards, auto-priority from the escrow value,
  /// and the court-thread opener — none of which the legacy path provided.
  ///
  /// [raisedByRole] is 'client' from the approve/dispute screen; the parameter
  /// exists so a provider-initiated dispute can reuse this method later.
  /// Returns the dispute_id (canonical identifier used for deep-link routing).
  static Future<String> dispute({
    required String postId,
    required String clientUserId,
    required String reason,
    String raisedByRole = 'client',
  }) async {
    final response = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/disputes/create'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'post_id': postId,
            'raised_by_user_id': clientUserId,
            'raised_by_role': raisedByRole,
            'reason': reason,
          }),
        )
        .timeout(_timeout);

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200 || response.statusCode == 201) {
      return json['dispute_id'] as String? ?? '';
    }
    throw JobsException(_extractMessage(json), statusCode: response.statusCode);
  }

  /// Client selects a provider — the ONLY supported path for provider assignment.
  /// Replaces any prior direct-Supabase writes for selected_provider_id.
  static Future<void> selectProvider({
    required String postId,
    required String providerId,
    required String clientUserId,
  }) async {
    debugPrint('[JOBS][SELECT_PROVIDER][REQUEST] postId=$postId providerId=$providerId');

    final response = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/jobs/select-provider'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'post_id': postId,
            'provider_id': providerId,
            'client_user_id': clientUserId,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode == 200 || response.statusCode == 201) {
      debugPrint('[JOBS][SELECT_PROVIDER][SUCCESS] postId=$postId providerId=$providerId');
      return;
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final msg = _extractMessage(json);
    debugPrint('[JOBS][SELECT_PROVIDER][ERROR] postId=$postId status=${response.statusCode} msg=$msg');
    throw JobsException(msg, statusCode: response.statusCode);
  }

  /// Poll the latest job completion status for a post.
  static Future<JobCompletionStatus?> getJobStatus(String postId) async {
    try {
      final response = await http
          .get(Uri.parse('${ApiConfig.baseUrl}/jobs/$postId/status'))
          .timeout(_timeout);

      if (response.statusCode == 200) {
        final body = response.body.trim();
        if (body == 'null' || body.isEmpty) return null;
        final json = jsonDecode(body) as Map<String, dynamic>?;
        if (json == null) return null;
        return JobCompletionStatus.fromJson(json);
      }
    } catch (e) {
      debugPrint('[JobsService] getJobStatus error: $e');
    }
    return null;
  }

  /// Archive (soft delete) a post via the backend. The server enforces the
  /// deletion policy (blocked while funds are in escrow or a dispute is active)
  /// and never hard-deletes. Throws [JobsException] with a user-facing message
  /// when archiving is not allowed.
  static Future<void> archivePost({
    required String postId,
    required String userId,
  }) async {
    final response = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/jobs/$postId/archive'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'user_id': userId}),
        )
        .timeout(_timeout);

    if (response.statusCode == 200 || response.statusCode == 201) return;
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    throw JobsException(_extractMessage(json), statusCode: response.statusCode);
  }

  /// Participant-scoped job lifecycle aggregate (payment + completion + dispute +
  /// timeline) — the single source of truth for the Job Lifecycle Detail screen.
  static Future<JobLifecycle> getLifecycle({
    required String postId,
    required String userId,
  }) async {
    final uri = Uri.parse(
      '${ApiConfig.baseUrl}/jobs/$postId/lifecycle?user_id=${Uri.encodeComponent(userId)}',
    );
    final response = await http.get(uri).timeout(_timeout);

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      return JobLifecycle.fromJson(json);
    }
    throw JobsException(_extractMessage(json), statusCode: response.statusCode);
  }

  static String _extractMessage(Map<String, dynamic> json) {
    final msg = json['message'];
    if (msg is List) return (msg as List<dynamic>).join('; ');
    if (msg is String) return msg;
    return 'Something went wrong. Please try again.';
  }
}
