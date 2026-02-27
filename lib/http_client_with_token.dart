import 'package:http/http.dart' as http;
import 'services/supabase_auth_bridge.dart';

/// HTTP client that injects Supabase JWT (from Firebase exchange) into requests.
/// Used by SupabaseConfig so RLS auth.jwt() sees the current user when token exchange works.
class HttpClientWithToken extends http.BaseClient {
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final token = SupabaseAuthBridge.currentToken;
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    return _inner.send(request);
  }
}
