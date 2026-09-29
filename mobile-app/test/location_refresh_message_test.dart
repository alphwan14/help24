import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/current_location_service.dart';

/// REFRESHING A LOCATION SAYS WHY IT FAILED.
///
/// Profile → Location → Refresh answered every failure with "Could not get
/// location. Try again." On a device in airplane mode the real cause was a
/// missing GPS fix — without Wi-Fi or mobile data Android loses assisted
/// positioning — and the remedy was to reconnect, which nothing said. But a
/// permission or a switched-off location toggle must never be reported as an
/// internet problem, offline or not.
void main() {
  String msg(CurrentLocationFailure f, {required bool offline}) =>
      CurrentLocationResult.failed(f).refreshMessage(offline: offline);

  const internet =
      "We couldn't update your location. Check your internet connection and try again.";

  group('offline', () {
    test('a missing or imprecise fix is the connection\'s doing', () {
      expect(msg(CurrentLocationFailure.noFix, offline: true), internet);
      expect(msg(CurrentLocationFailure.lowAccuracy, offline: true), internet);
      expect(msg(CurrentLocationFailure.unnamed, offline: true), internet);
    });

    test('permission and the device toggle keep their own remedies', () {
      expect(msg(CurrentLocationFailure.permissionDenied, offline: true),
          'Location permission is needed to update your location.');
      expect(msg(CurrentLocationFailure.permissionBlocked, offline: true),
          contains('Settings'));
      expect(msg(CurrentLocationFailure.serviceDisabled, offline: true),
          'Turn on location services and try again.');
      for (final f in [
        CurrentLocationFailure.permissionDenied,
        CurrentLocationFailure.permissionBlocked,
        CurrentLocationFailure.serviceDisabled,
      ]) {
        expect(msg(f, offline: true), isNot(contains('internet')), reason: f.name);
      }
    });
  });

  group('online', () {
    test('no failure is blamed on the internet', () {
      for (final f in CurrentLocationFailure.values) {
        expect(msg(f, offline: false), isNot(contains('internet')), reason: f.name);
      }
    });

    test('a missing fix points at the sky, not the network', () {
      expect(msg(CurrentLocationFailure.noFix, offline: false),
          "We couldn't get your location. Move to an open area and try again.");
      expect(msg(CurrentLocationFailure.lowAccuracy, offline: false),
          contains('precise'));
    });
  });

  test('every failure has a sentence, and none is the old catch-all', () {
    for (final offline in [true, false]) {
      for (final f in CurrentLocationFailure.values) {
        final m = msg(f, offline: offline);
        expect(m.trim(), isNotEmpty, reason: '${f.name} offline=$offline');
        expect(m, isNot('Could not get location. Try again.'));
      }
    }
  });

  test('the refresh sheet uses the reason, and colours success explicitly', () {
    final src = File('lib/screens/profile_screen.dart').readAsStringSync();
    expect(src.contains("'Could not get location. Try again.'"), isFalse);
    expect(src.contains('result.refreshMessage(offline: offline)'), isTrue);
    // A thrown platform error is mapped, not left silent.
    expect(src.contains('ErrorMapper.toMessage(e, context: ErrorContext.location)'), isTrue);
    expect(src.contains("_feedback!.contains('updated')"), isFalse,
        reason: 'success colour must not be inferred from the wording');
  });
}
