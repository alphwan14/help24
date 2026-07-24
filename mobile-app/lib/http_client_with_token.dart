import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'providers/connectivity_provider.dart' show NetworkHealth;
import 'services/supabase_auth_bridge.dart';

/// HTTP client that injects the Supabase JWT (from the Firebase exchange) into
/// every request, so RLS `auth.jwt() ->> 'user_id'` sees the current user.
///
/// It also OWNS expired-token recovery, because this is the one place every
/// PostgREST call passes through. Supabase JWTs expire (~1 h); before this, an
/// expired token was stamped onto requests forever and PostgREST answered
/// `401 PGRST303 "JWT expired"` to every read. Nothing re-exchanged, so a
/// device that had merely been signed in a while showed empty conversations,
/// empty message threads and "could not load the post" — while writes kept
/// working, because only the write path checked token freshness.
///
/// On a 401 we re-exchange once and replay the request. Concurrent 401s share
/// a single exchange (see [SupabaseAuthBridge.forceRefresh]).
class HttpClientWithToken extends http.BaseClient {
  final http.Client _inner = http.Client();

  /// Default ceiling for a PostgREST read/write, an auth call, or a
  /// `functions.invoke`. Without this, an expired data bundle (radio up, no
  /// bytes) leaves the send Future pending forever and the awaiting screen on
  /// a skeleton loader. A timeout converts that silent hang into a thrown
  /// [TimeoutException], which [NetworkHealth.failure] below turns into the
  /// app's offline signal and [ErrorMapper] turns into "The request took too
  /// long."
  static const Duration _defaultTimeout = Duration(seconds: 30);

  /// Storage transfers (image/evidence upload, signed-URL fetch) legitimately
  /// take longer than a query on a slow connection, so they get more headroom
  /// while still being bounded — an upload can no longer hang indefinitely.
  static const Duration _storageTimeout = Duration(seconds: 90);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Capture a replay copy BEFORE sending: a BaseRequest body is single-use.
    final replay = _replayFactory(request);
    final http.StreamedResponse response;
    try {
      response = await _sendOnce(request);
    } catch (e) {
      // Timeouts and socket errors are the app's most reliable signal that the
      // network is up but carrying nothing (an expired data bundle keeps the
      // radio on). Reported here — the one place every Supabase call passes
      // through — so reachability is derived from real traffic instead of a
      // separate polling loop. Suspicion only; the provider decides.
      NetworkHealth.failure();
      rethrow;
    }
    // A response of any status proves packets made the round trip.
    NetworkHealth.success();
    if (response.statusCode != 401 || replay == null) return response;

    final refreshed = await SupabaseAuthBridge.forceRefresh();
    if (!refreshed) return response;

    // Release the rejected response before reusing the connection.
    await response.stream.drain<void>();
    debugPrint('[AUTH][BRIDGE] 401 → token refreshed, replaying request');
    return _sendOnce(replay());
  }

  Future<http.StreamedResponse> _sendOnce(http.BaseRequest request) {
    final token = SupabaseAuthBridge.currentToken;
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    // The timeout bounds the wait for the server's response. It applies to both
    // the initial send and the post-401 replay, so no Supabase call can hang
    // forever regardless of which sub-client (PostgREST/storage/functions/auth)
    // issued it.
    return _inner.send(request).timeout(_timeoutFor(request));
  }

  /// Storage transfers get [_storageTimeout]; everything else [_defaultTimeout].
  Duration _timeoutFor(http.BaseRequest request) {
    if (request.url.path.contains('/storage/v1/')) return _storageTimeout;
    return _defaultTimeout;
  }

  /// A factory that rebuilds [request] for one retry, or null when replay is
  /// unsafe: the token-exchange call itself (guards against recursion) and
  /// streamed/multipart uploads (their bodies cannot be rewound).
  http.BaseRequest Function()? _replayFactory(http.BaseRequest request) {
    if (request.url.path.contains('/functions/v1/')) return null;
    if (request is! http.Request) return null;
    final bytes = request.bodyBytes;
    final headers = Map<String, String>.from(request.headers);
    final method = request.method;
    final url = request.url;
    final followRedirects = request.followRedirects;
    final maxRedirects = request.maxRedirects;
    final persistentConnection = request.persistentConnection;
    return () => http.Request(method, url)
      ..bodyBytes = bytes
      ..headers.addAll(headers)
      ..followRedirects = followRedirects
      ..maxRedirects = maxRedirects
      ..persistentConnection = persistentConnection;
  }
}
