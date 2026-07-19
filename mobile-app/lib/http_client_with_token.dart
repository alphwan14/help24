import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Capture a replay copy BEFORE sending: a BaseRequest body is single-use.
    final replay = _replayFactory(request);
    final response = await _sendOnce(request);
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
    return _inner.send(request);
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
