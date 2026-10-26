import 'package:firebase_auth/firebase_auth.dart' as fb show User;
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

  /// Ceiling for Firebase `getIdToken`. It goes through the Firebase SDK, not
  /// [HttpClientWithToken], so a network stall here would otherwise leave the
  /// token exchange (and every RLS write/read waiting on it) pending forever.
  static const Duration _idTokenTimeout = Duration(seconds: 20);

  /// Current JWT used for Supabase requests (read by custom HTTP client).
  static String? get currentToken => _accessToken;

  /// Ensures a FRESH Supabase JWT is set so RLS (auth.jwt()->>'user_id') passes.
  ///
  /// Delegates to [ensureSessionForWriteAsync] so reads and writes share one
  /// freshness rule. This previously returned early whenever any token existed,
  /// ignoring its age: once the Supabase JWT passed its 1 h expiry every read
  /// 401'd with PGRST303 "JWT expired" and never recovered, so conversations,
  /// message threads and post details all rendered empty on a device that had
  /// simply been signed in for a while.
  static Future<void> ensureSessionAsync() async {
    await ensureSessionForWriteAsync();
  }

  /// Re-exchanges unconditionally, ignoring the cached token — used when the
  /// server has told us the JWT is no longer acceptable (401 / PGRST303).
  /// Concurrent callers share ONE exchange: a burst of 401s from parallel
  /// reads must not trigger a burst of cloud-function calls.
  static Future<bool> forceRefresh() {
    final user = AuthService.currentFirebaseUser;
    if (user == null) return Future.value(false);
    return ensureSessionForUser(user, force: true);
  }

  /// Ensures we have a fresh Supabase JWT for RLS writes (chats, chat_messages).
  /// Re-exchanges only when the cached token is missing or older than [_tokenTtl].
  /// Returns true if a token is set, false if exchange failed (caller should not proceed with write).
  static Future<bool> ensureSessionForWriteAsync() {
    final user = AuthService.currentFirebaseUser;
    if (user == null) return Future.value(false);
    return ensureSessionForUser(user);
  }

  /// Whose Firebase account the cached JWT was minted for. A token is only
  /// ever reused for that same account; an account switch always exchanges.
  static String? _tokenUid;

  static Future<bool>? _exchangeInFlight;
  static String? _exchangeUid;

  /// THE one way to establish the session for [user].
  ///
  /// At startup the app used to exchange three times in ~1.2 s: AuthProvider's
  /// init and its first auth-state event each called the exchange directly
  /// (bypassing the cache), and a profile write that landed before either
  /// finished started its own. Now a fresh token for this same account is
  /// reused, an exchange already running for this account is joined, and only
  /// otherwise does it exchange — once. [force] skips the reuse (the server
  /// rejected the token) but still joins a running exchange: that one is fresh
  /// too, and a burst of 401s must not become a burst of exchanges.
  static Future<bool> ensureSessionForUser(fb.User user, {bool force = false}) {
    if (!force &&
        _tokenUid == user.uid &&
        _accessToken != null &&
        _accessToken!.isNotEmpty &&
        _tokenExchangedAt != null &&
        DateTime.now().difference(_tokenExchangedAt!) < _tokenTtl) {
      return Future.value(true);
    }
    final running = _exchangeInFlight;
    if (running != null && _exchangeUid == user.uid) return running;

    _exchangeUid = user.uid;
    final exchange = _exchangeFor(user, forceIdToken: force);
    _exchangeInFlight = exchange;
    exchange.whenComplete(() {
      if (identical(_exchangeInFlight, exchange)) {
        _exchangeInFlight = null;
        _exchangeUid = null;
      }
    });
    return exchange;
  }

  static Future<bool> _exchangeFor(fb.User user, {required bool forceIdToken}) async {
    try {
      // forceIdToken after a rejection: a stale Firebase ID token would only
      // buy another expired Supabase JWT.
      final idToken = await user.getIdToken(forceIdToken).timeout(_idTokenTimeout);
      if (idToken == null || idToken.isEmpty) return false;
      final ok = await setSupabaseSessionFromFirebase(idToken);
      // The account may have changed while this was in flight; only claim the
      // token for [user] if it is still the signed-in account.
      if (ok && AuthService.currentFirebaseUser?.uid == user.uid) _tokenUid = user.uid;
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
    _tokenUid = null;
    _loggedExchangeUnavailable = false;
    // Revert realtime to anon on logout.
    try {
      Supabase.instance.client.realtime.setAuth(null);
    } catch (_) {}
  }
}
