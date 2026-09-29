import 'package:flutter_test/flutter_test.dart';
import 'package:help24/utils/error_mapper.dart';
import 'package:http/http.dart' as http;

/// THE REAL TRANSPORT FAILURE, NOT A HAND-BUILT ONE.
///
/// For a DNS failure, package:http's IOClient throws a PRIVATE class —
/// `_ClientSocketException`, a ClientException that also implements
/// SocketException — and that object is exactly what Promote Business put on
/// screen. error_mapper_test.dart builds a ClientException with the same text;
/// this file makes the real library throw the real object and maps THAT.
///
/// Deliberately in its own file with no testWidgets: a widget-test binding
/// replaces HttpClient with a mock that answers 400 instead of failing.
void main() {
  test('a real failed host lookup from package:http reads as offline', () async {
    Object? thrown;
    try {
      // `.invalid` is reserved (RFC 2606) and can never resolve on any network,
      // so this fails the way a phone with no connection fails.
      await http
          .get(Uri.parse('https://api.help24.invalid/promotions/campaigns?user_id=uid_123'))
          .timeout(const Duration(seconds: 25));
    } catch (e) {
      thrown = e;
    }

    expect(thrown, isNotNull, reason: 'a .invalid host must never answer');
    final failure = ErrorMapper.toFailure(thrown, context: ErrorContext.loadContent);

    // A machine with no DNS at all may time out rather than fail the lookup;
    // both are connectivity, and both must read as such.
    expect(failure.isOffline, isTrue, reason: '$thrown');
    if (thrown is http.ClientException) {
      expect(failure.category, ErrorCategory.networkOffline);
      expect(failure.message,
          "You're offline. Check your internet connection and try again.");
    }

    final shown = '${failure.title} ${failure.message} ${failure.detail ?? ''}';
    for (final leak in ['Exception', 'Socket', 'host lookup', 'OS Error', 'errno',
        'help24.invalid', 'uri=', 'user_id']) {
      expect(shown.contains(leak), isFalse, reason: 'leaked "$leak": $shown');
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
