import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

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

  /// Client disputes the completion — freezes escrow.
  static Future<String> dispute({
    required String postId,
    required String clientUserId,
    required String reason,
  }) async {
    final response = await http
        .post(
          Uri.parse('${ApiConfig.baseUrl}/jobs/dispute'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'post_id': postId,
            'client_user_id': clientUserId,
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

  static String _extractMessage(Map<String, dynamic> json) {
    final msg = json['message'];
    if (msg is List) return (msg as List<dynamic>).join('; ');
    if (msg is String) return msg;
    return 'Something went wrong. Please try again.';
  }
}
