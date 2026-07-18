import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_auth_bridge.dart';

/// Valid report reasons — must mirror the CHECK constraint in migration 084.
enum ReportReason {
  spam('spam', 'Spam'),
  scamOrFraud('scam_or_fraud', 'Scam or fraud'),
  inappropriateContent('inappropriate_content', 'Inappropriate content'),
  harassment('harassment', 'Harassment'),
  other('other', 'Something else');

  final String value;
  final String label;
  const ReportReason(this.value, this.label);
}

/// Submits user reports from conversations into `user_reports` (migration
/// 084). Insert-only from the client; review happens in the admin dashboard.
class ReportService {
  ReportService._();

  /// Returns true when the report was stored. Fails softly (false) when the
  /// table isn't provisioned yet or the network is down — callers show a
  /// non-blaming error message.
  static Future<bool> submitUserReport({
    required String reporterId,
    required String reportedUserId,
    required ReportReason reason,
    String details = '',
    String? chatId,
    String? postId,
    String? messageId,
  }) async {
    if (reporterId.isEmpty || reportedUserId.isEmpty || reporterId == reportedUserId) {
      return false;
    }
    try {
      await SupabaseAuthBridge.ensureSessionForWriteAsync();
      await Supabase.instance.client.from('user_reports').insert({
        'reporter_id': reporterId,
        'reported_user_id': reportedUserId,
        'reason': reason.value,
        'details': details.trim(),
        if (chatId != null && chatId.isNotEmpty) 'chat_id': chatId,
        if (postId != null && postId.isNotEmpty) 'post_id': postId,
        if (messageId != null && messageId.isNotEmpty) 'message_id': messageId,
      });
      return true;
    } catch (e) {
      debugPrint('ReportService submitUserReport: $e');
      return false;
    }
  }
}
