import 'dart:convert';

// Goes through the authenticated client so the Firebase ID token is attached:
// both endpoints bind identity from it (@Auth('query.user_id')), so a caller
// cannot read someone else's history or receipt by typing their id.
import 'api_client.dart';
import '../config/api_config.dart';
import '../models/service_record.dart';

class ServiceRecordsException implements Exception {
  final String message;
  final int? statusCode;
  ServiceRecordsException(this.message, {this.statusCode});
  @override
  String toString() => 'ServiceRecordsException: $message';
}

/// Service Records — a user's job history and the Help24 receipt for a job.
///
/// Both reads go through the backend rather than Supabase, and must: the
/// `job_completions` and `disputes` tables are RLS service-role-only, so the
/// provider side of a work history is not readable from a device at all, and
/// settlement state is derived server-side by the one canonical state machine.
class ServiceRecordsService {
  static const Duration _timeout = Duration(seconds: 30);

  /// A page of the caller's service records.
  /// [role] is 'client' for services bought, 'provider' for work done.
  static Future<ServiceHistory> getHistory({
    required String userId,
    required String role,
    int limit = 30,
    int offset = 0,
  }) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/jobs/history').replace(queryParameters: {
      'user_id': userId,
      'role': role,
      'limit': '$limit',
      'offset': '$offset',
    });

    final response = await api.get(uri).timeout(_timeout);
    if (response.statusCode == 200) {
      return ServiceHistory.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw _failure(response.statusCode, response.body);
  }

  /// The Help24 receipt for a job, or an honest reason there is not one yet.
  ///
  /// A 200 carrying `available: false` is a normal answer, not a failure: it is
  /// how a payment that is still processing reports itself. Only a non-200 is
  /// an error.
  static Future<ReceiptResult> getReceipt({
    required String postId,
    required String userId,
  }) async {
    final uri = Uri.parse(
      '${ApiConfig.baseUrl}/jobs/$postId/receipt?user_id=${Uri.encodeComponent(userId)}',
    );

    final response = await api.get(uri).timeout(_timeout);
    if (response.statusCode == 200) {
      return ReceiptResult.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    }
    throw _failure(response.statusCode, response.body);
  }

  /// The exception for a non-200, always carrying its status. The body was
  /// decoded BEFORE the status check, so a hosting proxy's HTML 502 page threw
  /// a FormatException instead — no status, and "Unexpected character" where
  /// "Help24 is temporarily unavailable" belonged.
  static ServiceRecordsException _failure(int statusCode, String body) {
    var message = 'Something went wrong. Please try again.';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) message = _extractMessage(decoded);
    } catch (_) {
      // Not JSON. The status code carries the meaning.
    }
    return ServiceRecordsException(message, statusCode: statusCode);
  }

  static String _extractMessage(Map<String, dynamic> json) {
    final msg = json['message'];
    if (msg is List) return msg.join('; ');
    if (msg is String) return msg;
    return 'Something went wrong. Please try again.';
  }
}
