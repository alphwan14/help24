import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/notification_service.dart';

// Found on device 2026-10-29: when a push had already started the process for
// its background handler, one tap arrived twice — through the live callback
// AND as getNotificationAppLaunchDetails() — and the chat was opened twice.
void main() {
  NotificationResponse tap(int id, String payload) => NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        id: id,
        payload: payload,
      );

  setUp(NotificationService.resetTapDedupeForTest);

  test('the same tap delivered twice is routed once', () {
    final t0 = DateTime(2026, 10, 29, 20, 44);
    expect(NotificationService.shouldRouteTap(tap(7, '{"chat_id":"a"}'), t0), isTrue);
    expect(
      NotificationService.shouldRouteTap(tap(7, '{"chat_id":"a"}'), t0.add(const Duration(milliseconds: 300))),
      isFalse,
    );
  });

  test('a later message in the same thread (same id, new payload) is routed', () {
    // Chat notifications reuse one id per thread; the payload differs per message.
    final t0 = DateTime(2026, 10, 29, 20, 44);
    expect(NotificationService.shouldRouteTap(tap(7, '{"m":"1"}'), t0), isTrue);
    expect(NotificationService.shouldRouteTap(tap(7, '{"m":"2"}'), t0.add(const Duration(seconds: 1))), isTrue);
  });

  test('the same notification tapped again much later is routed', () {
    final t0 = DateTime(2026, 10, 29, 20, 44);
    expect(NotificationService.shouldRouteTap(tap(7, '{"m":"1"}'), t0), isTrue);
    expect(NotificationService.shouldRouteTap(tap(7, '{"m":"1"}'), t0.add(const Duration(minutes: 1))), isTrue);
  });
}
