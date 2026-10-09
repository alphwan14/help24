import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/user_profile_service.dart';

/// A DEVICE'S PUSH TOKEN BELONGS TO WHOEVER IS SIGNED IN ON IT NOW.
///
/// Found 2026-10-09 on the A21s against production: after one account signed
/// out and another signed in, the phone's `fcm_tokens` row still belonged to
/// the first account. The second account's `upsert(onConflict: token)` became
/// an UPDATE of a row it did not own, RLS refused it (42501), the app logged
/// "saved" anyway — and the new account got no pushes while the signed-out one
/// still did. Migration 121 adds `register_fcm_token`, which assigns the token
/// to the caller from the verified JWT; the app registers through it.
void main() {
  group('the app registers through the claiming function', () {
    final src = File('lib/services/user_profile_service.dart').readAsStringSync();

    test('register_fcm_token is called with the token and platform only', () {
      expect(src, contains("rpc('register_fcm_token'"));
      expect(src, contains("'p_token': token"));
      // The owner comes from the JWT on the server, never from the client.
      final call = src.substring(src.indexOf("rpc('register_fcm_token'"));
      expect(call.substring(0, call.indexOf('});')), isNot(contains('user_id')));
    });

    test('a failed registration is reported, not logged as saved', () {
      final notify = File('lib/services/notification_service.dart').readAsStringSync();
      expect(notify, isNot(contains("debugPrint('[FCM][TOKEN] saved for uid")));
      expect(notify, isNot(contains("debugPrint('[FCM][LOGIN] token saved for uid")));
      expect(notify, contains("'NOT saved'"));
    });

    test('sign-out fetches the token when this process never had it', () {
      final notify = File('lib/services/notification_service.dart').readAsStringSync();
      final logout = notify.substring(notify.indexOf('static Future<void> removeTokenOnLogout'));
      final body = logout.substring(0, logout.length < 700 ? logout.length : 700);
      expect(body, contains('_messaging.getToken()'));
      expect(body, isNot(contains('if (_currentToken != null)')));
    });
  });

  group('falling back only when the function is missing', () {
    test('PostgREST and Postgres "no such function" are recognised', () {
      expect(UserProfileService.isMissingFunction(code: 'PGRST202'), isTrue);
      expect(UserProfileService.isMissingFunction(code: '42883'), isTrue);
      expect(
        UserProfileService.isMissingFunction(
          message: 'Could not find the function public.register_fcm_token(p_platform, p_token)',
        ),
        isTrue,
      );
    });

    test('anything else is a real failure, not a reason to bypass it', () {
      expect(UserProfileService.isMissingFunction(code: '42501'), isFalse);
      expect(UserProfileService.isMissingFunction(code: '23503'), isFalse);
      expect(UserProfileService.isMissingFunction(message: 'network unreachable'), isFalse);
    });
  });

  group('migration 121 stays narrow', () {
    final sql = File('../supabase/migrations/121_fcm_token_claim.sql').readAsStringSync();

    test('the owner is the JWT caller, and only signed-in callers may run it', () {
      expect(sql, contains("auth.jwt() ->> 'user_id'"));
      expect(sql, contains('SECURITY DEFINER'));
      expect(sql, contains('SET search_path = public, pg_temp'));
      expect(sql, contains('REVOKE ALL ON FUNCTION public.register_fcm_token(text, text) FROM anon'));
      expect(sql, contains('GRANT EXECUTE ON FUNCTION public.register_fcm_token(text, text) TO authenticated'));
    });

    test('no policy on the table is loosened', () {
      expect(RegExp(r'\b(CREATE|ALTER|DROP)\s+POLICY\b', caseSensitive: false).hasMatch(sql), isFalse);
      expect(RegExp(r'\bGRANT\b[^;]*\bON\s+(TABLE\s+)?public\.fcm_tokens', caseSensitive: false).hasMatch(sql),
          isFalse);
    });
  });
}
