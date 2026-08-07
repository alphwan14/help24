import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/notification_capability.dart';

/// Regression matrix for finding H1 (launch-readiness-verification-report):
/// FCM said `authorized` while the OS had notifications blocked, and the app
/// believed FCM. The rule under test: the OS answer outranks Firebase's.
void main() {
  group('resolveNotificationCapability', () {
    test('the H1 case: FCM authorized but OS blocked → osBlocked, never enabled', () {
      // Observed on SM-A217F / Android 12: dumpsys allowNoti=false while
      // authorizationStatus=authorized.
      expect(
        resolveNotificationCapability(fcmAuthorized: true, osEnabled: false),
        NotificationCapability.osBlocked,
      );
    });

    test('OS blocked outranks even an FCM denial (settings fix comes first)', () {
      expect(
        resolveNotificationCapability(fcmAuthorized: false, osEnabled: false),
        NotificationCapability.osBlocked,
      );
    });

    test('Android 13 prompt refused: OS toggle on, FCM denied → denied', () {
      expect(
        resolveNotificationCapability(fcmAuthorized: false, osEnabled: true),
        NotificationCapability.denied,
      );
    });

    test('both agree → enabled', () {
      expect(
        resolveNotificationCapability(fcmAuthorized: true, osEnabled: true),
        NotificationCapability.enabled,
      );
    });

    test('platform without an OS answer falls back to FCM: authorized → enabled', () {
      expect(
        resolveNotificationCapability(fcmAuthorized: true, osEnabled: null),
        NotificationCapability.enabled,
      );
    });

    test('platform without an OS answer falls back to FCM: denied → denied', () {
      expect(
        resolveNotificationCapability(fcmAuthorized: false, osEnabled: null),
        NotificationCapability.denied,
      );
    });
  });
}
