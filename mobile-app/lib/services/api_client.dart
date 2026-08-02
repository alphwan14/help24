import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import '../providers/connectivity_provider.dart' show NetworkHealth;

/// The HTTP client for the Help24 backend, and the only one that should be used
/// for it.
///
/// WHY THIS EXISTS
/// ---------------
/// Until now every backend call was a bare `http.post(...)` that sent the
/// caller's identity in the request BODY (`client_user_id`, `buyer_user_id`,
/// `senderId`) and no `Authorization` header at all. Firebase ID tokens were
/// minted on this device, but only ever to exchange for a Supabase session —
/// the Help24 backend never saw one, so it had no way to tell a real user from
/// anyone who could type that user's id into a JSON body.
///
/// This client attaches the Firebase ID token to every backend request. The
/// server binds the verified UID onto the identity field each route declares,
/// which is what makes the ownership checks that already exist in every service
/// actually mean something.
///
/// RELATIONSHIP TO [HttpClientWithToken]
/// -------------------------------------
/// They are deliberately separate and carry DIFFERENT credentials:
///
///   HttpClientWithToken → Supabase. Carries the EXCHANGED Supabase JWT, so
///                         PostgREST RLS sees `auth.jwt()->>'user_id'`.
///   Help24ApiClient     → our backend. Carries the RAW Firebase ID token,
///                         which the backend verifies with the Admin SDK.
///
/// Sending the Supabase JWT to our backend would fail verification (wrong
/// issuer), and sending the Firebase token to Supabase would fail RLS. The two
/// must not be merged.
///
/// TOKEN LIFECYCLE
/// ---------------
/// Firebase ID tokens last an hour. `getIdToken()` refreshes automatically when
/// one is close to expiry, but it is an async platform-channel call, so doing it
/// per request adds latency to every screen. The token is therefore cached here
/// until shortly before its own expiry, and force-refreshed on a `TOKEN_EXPIRED`
/// response — the same shape of recovery [HttpClientWithToken] performs for
/// Supabase, for the same reason: an expired credential must self-heal rather
/// than leave a signed-in user looking signed out.
class Help24ApiClient extends http.BaseClient {
  Help24ApiClient._();

  static final Help24ApiClient instance = Help24ApiClient._();

  final http.Client _inner = http.Client();

  /// Matches the ceiling the individual services already used for backend calls.
  static const Duration _defaultTimeout = Duration(seconds: 30);

  /// Refresh this long before the token's own expiry. Covers clock skew between
  /// the device and Google, and the flight time of the request itself — a token
  /// that is valid when we attach it must still be valid when it arrives.
  static const Duration _refreshMargin = Duration(minutes: 5);

  String? _cachedToken;
  DateTime? _cachedExpiry;
  Future<String?>? _fetchInFlight;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Capture a replay copy BEFORE sending: a BaseRequest body is single-use.
    final replay = _replayFactory(request);

    http.StreamedResponse response;
    try {
      response = await _sendOnce(request, forceFreshToken: false);
    } catch (e) {
      // Same reasoning as HttpClientWithToken: a timeout or socket error is the
      // app's most reliable signal that the radio is up but carrying nothing.
      NetworkHealth.failure();
      rethrow;
    }
    NetworkHealth.success();

    if (response.statusCode != 401 || replay == null) return response;

    // A 401 that is NOT about token freshness must not trigger a refresh loop —
    // re-minting a token cannot fix "you are not allowed to do this".
    final body = await response.stream.bytesToString();
    if (!_isExpiredToken(body)) {
      return http.StreamedResponse(
        Stream.value(utf8.encode(body)),
        response.statusCode,
        headers: response.headers,
        reasonPhrase: response.reasonPhrase,
        request: response.request,
      );
    }

    debugPrint('[API] 401 TOKEN_EXPIRED → refreshing Firebase token and replaying once');
    _invalidateToken();
    return _sendOnce(replay(), forceFreshToken: true);
  }

  Future<http.StreamedResponse> _sendOnce(
    http.BaseRequest request, {
    required bool forceFreshToken,
  }) async {
    final token = await _idToken(forceRefresh: forceFreshToken);
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    // No token means no signed-in user. The request still goes out WITHOUT the
    // header, because the public surface — Discover, provider profiles, package
    // pricing — is meant to work for someone who has not signed up yet. The
    // server answers 401 if the route actually needed an identity.
    return _inner.send(request).timeout(_defaultTimeout);
  }

  /// The current Firebase ID token, cached until shortly before it expires.
  ///
  /// Concurrent callers share ONE fetch: an app opening several screens at once
  /// issues a burst of backend calls, and each triggering its own platform-
  /// channel round trip would serialise the whole burst behind the SDK.
  Future<String?> _idToken({required bool forceRefresh}) {
    if (!forceRefresh) {
      final token = _cachedToken;
      final expiry = _cachedExpiry;
      if (token != null && expiry != null && DateTime.now().isBefore(expiry)) {
        return Future.value(token);
      }
    }
    return _fetchInFlight ??= _fetchToken(forceRefresh).whenComplete(() {
      _fetchInFlight = null;
    });
  }

  Future<String?> _fetchToken(bool forceRefresh) async {
    final user = AuthService.currentFirebaseUser;
    if (user == null) {
      _invalidateToken();
      return null;
    }
    try {
      // getIdTokenResult gives the token AND its expiry, so the cache window is
      // derived from the credential itself rather than from a guessed TTL.
      final result = await user.getIdTokenResult(forceRefresh).timeout(_defaultTimeout);
      final token = result.token;
      if (token == null || token.isEmpty) {
        _invalidateToken();
        return null;
      }
      _cachedToken = token;
      final expiration = result.expirationTime;
      _cachedExpiry = expiration != null
          ? expiration.subtract(_refreshMargin)
          : DateTime.now().add(const Duration(minutes: 30));
      return token;
    } catch (e) {
      // Never fatal. A backend call without a token is exactly the pre-migration
      // behaviour, and the server decides whether that is acceptable per route.
      debugPrint('[API] could not obtain a Firebase ID token: $e');
      _invalidateToken();
      return null;
    }
  }

  void _invalidateToken() {
    _cachedToken = null;
    _cachedExpiry = null;
  }

  /// Drop the cached token. Call on sign-out so the next request cannot carry
  /// the previous user's credential.
  void clearSession() => _invalidateToken();

  /// True when the backend said this specific request failed on token freshness.
  ///
  /// Reads the machine-readable `code` rather than the message: the server's
  /// prose is user-facing and may be reworded, but `TOKEN_EXPIRED` is a contract.
  bool _isExpiredToken(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded['code'] == 'TOKEN_EXPIRED';
    } catch (_) {
      // Not JSON — treat as a genuine 401 rather than retrying blindly.
    }
    return false;
  }

  /// A factory that rebuilds [request] for one retry, or null when replay is
  /// unsafe (streamed/multipart bodies cannot be rewound).
  http.BaseRequest Function()? _replayFactory(http.BaseRequest request) {
    if (request is! http.Request) return null;
    final bytes = request.bodyBytes;
    final headers = Map<String, String>.from(request.headers);
    final method = request.method;
    final url = request.url;
    return () => http.Request(method, url)
      ..bodyBytes = bytes
      ..headers.addAll(headers);
  }
}

/// Shorthand for the call sites: `api.post(...)` instead of `http.post(...)`.
///
/// Deliberately the same surface as `package:http`'s top-level functions, so
/// migrating a call site is a one-word change and nothing about how requests are
/// written has to be relearned.
final Help24ApiClient api = Help24ApiClient.instance;
