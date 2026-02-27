import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';

/// Bridges Firebase Auth to Supabase so RLS (auth.jwt()->>'user_id') works.
/// Exchanges Firebase ID token for a Supabase JWT and injects it via custom HTTP client.
/// Call [setSupabaseSessionFromFirebase] after Firebase login and on app start if user is logged in.
/// Call [ensureSessionAsync] before Supabase writes that require RLS (e.g. chat_messages insert).
/// Call [clearSupabaseSession] on Firebase sign out.
class SupabaseAuthBridge {
  static const String _functionName = 'exchange-firebase-token';

  static String? _accessToken;
  static bool _loggedExchangeUnavailable = false;

  /// Current JWT used for Supabase requests (read by custom HTTP client).
  static String? get currentToken => _accessToken;

  /// Ensures the Supabase JWT is set so RLS (auth.jwt()->>'user_id') passes.
  /// Call before inserting into chat_messages or other RLS-protected writes.
  static Future<void> ensureSessionAsync() async {
    if (_accessToken != null && _accessToken!.isNotEmpty) return;
    final user = AuthService.currentFirebaseUser;
    if (user == null) return;
    try {
      final idToken = await user.getIdToken();
      if (idToken != null && idToken.isNotEmpty) {
        await setSupabaseSessionFromFirebase(idToken);
      }
    } catch (_) {
      // Token exchange often fails in browser (CORS). App works with relaxed RLS.
      if (!_loggedExchangeUnavailable) {
        _loggedExchangeUnavailable = true;
        debugPrint('SupabaseAuthBridge: token exchange unavailable (e.g. web). Using anon key.');
      }
    }
  }

  /// Ensures we have a fresh Supabase JWT for RLS writes (chats, chat_messages).
  /// Always performs exchange (no cache skip) so expired tokens don't cause 42501.
  /// Returns true if a token is set, false if exchange failed (caller should not proceed with write).
  static Future<bool> ensureSessionForWriteAsync() async {
    final user = AuthService.currentFirebaseUser;
    if (user == null) return false;
    try {
      final idToken = await user.getIdToken();
      if (idToken == null || idToken.isEmpty) return false;
      final ok = await setSupabaseSessionFromFirebase(idToken);
      return ok;
    } catch (_) {
      if (!_loggedExchangeUnavailable) {
        _loggedExchangeUnavailable = true;
        debugPrint('SupabaseAuthBridge: token exchange unavailable (e.g. web). Using anon key.');
      }
      return false;
    }
  }

  /// Call with Firebase ID token. Exchanges it for a Supabase JWT and stores it.
  /// Returns true if token was set, false on failure (logs and does not throw).
  static Future<bool> setSupabaseSessionFromFirebase(String idToken) async {
    if (idToken.isEmpty) return false;
    try {
      final client = Supabase.instance.client;
      final response = await client.functions.invoke(
        _functionName,
        body: {'id_token': idToken},
        method: HttpMethod.post,
      );
      if (response.status != 200) return false;
      final data = response.data as Map<String, dynamic>?;
      final accessToken = data?['access_token'] as String?;
      if (accessToken == null || accessToken.isEmpty) return false;
      _accessToken = accessToken;
      return true;
    } catch (_) {
      if (!_loggedExchangeUnavailable) {
        _loggedExchangeUnavailable = true;
        debugPrint('SupabaseAuthBridge: token exchange unavailable (e.g. web CORS). Using anon key.');
      }
      return false;
    }
  }

  /// Clear stored token (call on Firebase sign out).
  static void clearSupabaseSession() {
    _accessToken = null;
    _loggedExchangeUnavailable = false;
  }
}
