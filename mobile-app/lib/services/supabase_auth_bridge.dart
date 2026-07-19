import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';
import 'dart:async';

/// Bridges Firebase Auth to Supabase so RLS (auth.jwt()->>'user_id') works.
/// Exchanges Firebase ID token for a Supabase JWT and injects it via custom HTTP client.
/// Call [setSupabaseSessionFromFirebase] after Firebase login and on app start if user is logged in.
/// Call [ensureSessionAsync] before Supabase writes that require RLS (e.g. chat_messages insert).
/// Call [clearSupabaseSession] on Firebase sign out.
class SupabaseAuthBridge {
  static const String _functionName = 'exchange-firebase-token';

  static String? _accessToken;
  static DateTime? _tokenExchangedAt;
  // Conservative TTL: Firebase ID tokens expire in 1 h; re-exchange after 50 min.
  static const Duration _tokenTtl = Duration(minutes: 50);
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
    } catch (e) {
      if (!_loggedExchangeUnavailable) {
        _loggedExchangeUnavailable = true;
        debugPrint('[AUTH][BRIDGE] ok=false — exchange error: $e (using anon key)');
      }
    }
  }

  /// Ensures we have a fresh Supabase JWT for RLS writes (chats, chat_messages).
  /// Re-exchanges only when the cached token is missing or older than [_tokenTtl].
  /// Returns true if a token is set, false if exchange failed (caller should not proceed with write).
  static Future<bool> ensureSessionForWriteAsync() async {
    // Re-use valid token — avoids a cloud function call on every write.
    if (_accessToken != null &&
        _accessToken!.isNotEmpty &&
        _tokenExchangedAt != null &&
        DateTime.now().difference(_tokenExchangedAt!) < _tokenTtl) {
      return true;
    }
    final user = AuthService.currentFirebaseUser;
    if (user == null) return false;
    try {
      final idToken = await user.getIdToken();
      if (idToken == null || idToken.isEmpty) return false;
      final ok = await setSupabaseSessionFromFirebase(idToken);
      return ok;
    } catch (e) {
      if (!_loggedExchangeUnavailable) {
        _loggedExchangeUnavailable = true;
        debugPrint('[AUTH][BRIDGE] ok=false — exchange error: $e (using anon key)');
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
      if (response.status != 200) {
        debugPrint('[AUTH][BRIDGE] ok=false — status=${response.status} data=${response.data}');
        return false;
      }
      final data = response.data as Map<String, dynamic>?;
      final accessToken = data?['access_token'] as String?;
      if (accessToken == null || accessToken.isEmpty) {
        debugPrint('[AUTH][BRIDGE] ok=false — 200 but no access_token in response');
        return false;
      }
      _accessToken = accessToken;
      _tokenExchangedAt = DateTime.now();

      // Update the Supabase Realtime WebSocket connection so that realtime
      // subscriptions (postgres_changes) also use the authenticated JWT.
      // Without this the WebSocket stays on the anon role and RLS-filtered
      // realtime events are blocked.
      //
      // AWAITED, not fire-and-forget: callers (watchMessages) resolve the
      // session immediately before joining a channel. Leaving this unawaited
      // let a channel join while the socket was still on `anon`, which Realtime
      // rejects at authorisation time — a permanently dead subscription.
      await _updateRealtimeAuth(accessToken);

      debugPrint('[AUTH][BRIDGE] ok=true — authenticated JWT active for RLS');
      return true;
    } catch (e) {
      if (!_loggedExchangeUnavailable) {
        _loggedExchangeUnavailable = true;
        debugPrint('[AUTH][BRIDGE] ok=false — exchange error: $e (using anon key)');
      }
      return false;
    }
  }

  static Future<void> _updateRealtimeAuth(String token) async {
    try {
      Supabase.instance.client.realtime.setAuth(token);
      debugPrint('SupabaseAuthBridge: realtime auth token updated');
    } catch (e) {
      debugPrint('SupabaseAuthBridge: realtime setAuth failed: $e');
    }
  }

  /// Clear stored token (call on Firebase sign out).
  static void clearSupabaseSession() {
    _accessToken = null;
    _tokenExchangedAt = null;
    _loggedExchangeUnavailable = false;
    // Revert realtime to anon on logout.
    try {
      Supabase.instance.client.realtime.setAuth(null);
    } catch (_) {}
  }
}
