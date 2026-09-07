import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/widgets/notification_banner.dart';

/// THE IN-APP MESSAGE BANNER: APPEARANCE, GESTURE, LIFETIME.
///
/// WHAT WENT WRONG
/// ---------------
/// Measured on a Galaxy S20+ (Android 13) with a real chat_message push:
/// swiping the banner left or right moved it by exactly zero pixels, and a
/// slow drag upward did nothing either. Only a fast upward FLING dismissed it.
///
/// That was not "swipe was not implemented". The card carried a GestureDetector
/// with `onTap` and `onVerticalDragEnd` and nothing else, so:
///
///   * `GestureDetector` only instantiates the recognisers its callbacks ask
///     for. With no `onHorizontalDrag*`, no HorizontalDragGestureRecognizer was
///     ever put in the arena — a sideways drag had nothing to win it, the tap
///     recogniser rejected itself past kTouchSlop, and the gesture died.
///   * The one drag that WAS handled was handled at `End` only. With no
///     `onVerticalDragUpdate` the card never moved under the finger, and with
///     no displacement threshold the decision rested entirely on release
///     velocity — so a deliberate slow drag ended at ~0 px/s and was discarded
///     after the user had already watched nothing happen.
///
/// Two lifetime bugs sat underneath it, both invisible until timed exactly:
///
///   * Dismissal was a static method closing over a static `_entry`. The exit
///     animation took 300ms; a second message inside that window replaced
///     `_entry`, and the FIRST banner's completion callback then removed the
///     SECOND one.
///   * A tap reversed the animation and only called `onTap` after it finished.
///     The 4s auto-dismiss timer was still running, so a tap at 3.9s removed
///     the entry mid-animation, disposed the controller, cancelled the
///     TickerFuture — and the navigation it was carrying never happened.
///
/// These are real widget tests rather than source guards: the banner takes no
/// Firebase, Supabase or network dependency, so the behaviour can simply be
/// driven.
void main() {
  const sender = 'Alphonse Lincoln';
  const preview = 'Hi, I can be there by 2pm - does that work?';

  late GlobalKey<NavigatorState> navKey;

  /// Mounts a host app and shows one banner through the real public entry
  /// point, then lets the entrance animation finish.
  Future<void> showBanner(
    WidgetTester tester, {
    String title = sender,
    String body = preview,
    String type = 'chat_message',
    String avatarUrl = '',
    VoidCallback? onTap,
    Duration displayDuration = const Duration(seconds: 4),
    Brightness brightness = Brightness.light,
    bool alreadyMounted = false,
  }) async {
    if (!alreadyMounted) {
      navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navKey,
        theme: ThemeData(brightness: brightness),
        home: const Scaffold(body: SizedBox.expand()),
      ));
    }
    NotificationBannerOverlay.show(
      context: navKey.currentContext!,
      overlay: navKey.currentState!.overlay,
      title: title,
      body: body,
      type: type,
      avatarUrl: avatarUrl,
      onTap: onTap,
      displayDuration: displayDuration,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Ends a test that deliberately leaves the banner on screen.
  ///
  /// It has to happen inside the test body: testWidgets verifies that no Timer
  /// is pending BEFORE tearDown runs, so a banner still counting down here is
  /// reported as a leak — which is exactly the check we want to keep sharp.
  Future<void> closeBanner(WidgetTester tester) async {
    NotificationBannerOverlay.debugReset();
    await tester.pump();
  }

  tearDown(() {
    // A banner left mounted would leak its auto-dismiss Timer into the next
    // test — and testWidgets fails a test that ends with a pending timer, so
    // this is also what keeps that failure meaningful when it does happen.
    NotificationBannerOverlay.debugReset();
  });

  // ── What it says ───────────────────────────────────────────────────────────

  group('presentation', () {
    testWidgets('shows the sender, the preview and the Help24 category',
        (tester) async {
      await showBanner(tester);

      expect(find.text(sender), findsOneWidget);
      expect(find.text(preview), findsOneWidget);
      // The eyebrow comes from the notification registry, not a second table.
      expect(find.text('Messages'), findsOneWidget);
      await closeBanner(tester);
    });

    testWidgets('uses the sender initials, not a generic glyph', (tester) async {
      await showBanner(tester);
      expect(find.text('AL'), findsOneWidget);
      await closeBanner(tester);
    });

    testWidgets('a non-message type gets its own label and icon',
        (tester) async {
      await showBanner(tester,
          title: 'Payment secured',
          body: 'KES 2,500 is held in escrow',
          type: 'payment_secured');

      expect(find.text('Payments'), findsOneWidget);
      // Not a person, so no initials avatar.
      expect(find.text('PS'), findsNothing);
      await closeBanner(tester);
    });

    testWidgets('an unknown backend type still renders rather than throwing',
        (tester) async {
      await showBanner(tester, title: 'Something new', type: 'not_shipped_yet');
      expect(find.text('Something new'), findsOneWidget);
      await closeBanner(tester);
    });

    testWidgets('renders in dark mode without falling back to a white card',
        (tester) async {
      await showBanner(tester, brightness: Brightness.dark);

      final decoration = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.boxShadow != null);
      // Opaque, and NOT the light surface. The old card was 0.97 alpha, which
      // let the page title read straight through the message.
      expect(decoration.color!.a, 1.0);
      expect(decoration.color, isNot(Colors.white));
      await closeBanner(tester);
    });

    testWidgets('shows the sender photo when the app already has it',
        (tester) async {
      await showBanner(tester, avatarUrl: 'https://example.test/avatar.jpg');

      final image = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(image.imageUrl, 'https://example.test/avatar.jpg');
      await closeBanner(tester);
    });

    testWidgets('falls back to initials when the photo cannot be loaded',
        (tester) async {
      // No network in a widget test, so this exercises the errorWidget path —
      // which is the same path a broken or not-yet-cached URL takes on device.
      await showBanner(tester, avatarUrl: 'https://example.test/avatar.jpg');
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('AL'), findsOneWidget);
      await closeBanner(tester);
    });

    testWidgets('no photo means initials and no image widget at all',
        (tester) async {
      await showBanner(tester);

      expect(find.byType(CachedNetworkImage), findsNothing);
      expect(find.text('AL'), findsOneWidget);
      await closeBanner(tester);
    });

    testWidgets('a non-message notification never shows a sender photo',
        (tester) async {
      await showBanner(tester,
          title: 'Payment secured',
          type: 'payment_secured',
          avatarUrl: 'https://example.test/avatar.jpg');

      // A payment is not a person. The registry icon owns that slot.
      expect(find.byType(CachedNetworkImage), findsNothing);
      await closeBanner(tester);
    });

    testWidgets('text inherits a real style, not the monospace fallback',
        (tester) async {
      await showBanner(tester);

      // An OverlayEntry is mounted outside the Scaffold, so nothing here
      // inherits a DefaultTextStyle on its own. Drop the Material ancestor and
      // every line renders in monospace under a yellow debug underline — which
      // is precisely what shipped to the device on the first build of this
      // redesign. Cheap to assert, impossible to notice in a unit test
      // otherwise.
      expect(
        find.ancestor(
          of: find.text(sender),
          matching: find.byType(Material),
        ),
        findsWidgets,
      );
      final paragraph = tester.renderObject<RenderParagraph>(find.text(sender));
      expect(paragraph.text.style?.decoration, isNot(TextDecoration.underline));
      expect(paragraph.text.style?.fontFamily, isNot('monospace'));
      await closeBanner(tester);
    });

    testWidgets('an empty body does not leave a blank line', (tester) async {
      await showBanner(tester, body: '');
      expect(find.text(sender), findsOneWidget);
      expect(find.text(''), findsNothing);
      await closeBanner(tester);
    });
  });

  // ── Initials ───────────────────────────────────────────────────────────────

  group('initialsOf', () {
    test('takes the first and last word', () {
      expect(initialsOf('Alphonse Lincoln'), 'AL');
      expect(initialsOf('Mary Jane Wanjiru'), 'MW');
    });

    test('handles one word, padding and emptiness', () {
      expect(initialsOf('Timothy'), 'T');
      expect(initialsOf('   Babel   Damien  '), 'BD');
      expect(initialsOf(''), '?');
      expect(initialsOf('   '), '?');
    });

    test('does not slice a non-BMP first character in half', () {
      // A surrogate pair. substring(0, 1) would return half a code point and
      // render as a replacement box in the avatar.
      final result = initialsOf('\u{1F600}mile Otieno');
      expect(result.runes.length, 2);
      expect(result.runes.first, 0x1F600);
    });
  });

  // ── Tap ────────────────────────────────────────────────────────────────────

  group('tap', () {
    testWidgets('opens the chat and dismisses', (tester) async {
      var taps = 0;
      await showBanner(tester, onTap: () => taps++);

      await tester.tap(find.text(sender));
      await tester.pumpAndSettle();

      expect(taps, 1);
      expect(NotificationBannerOverlay.isVisible, isFalse);
      expect(find.text(sender), findsNothing);
    });

    testWidgets('routes on the frame of the tap, not after the animation',
        (tester) async {
      var taps = 0;
      await showBanner(tester, onTap: () => taps++);

      await tester.tap(find.text(sender));
      await tester.pump(); // one frame — the exit has barely started

      // This is the bug that lost a tap at 3.9s: routing used to wait for a
      // 300ms reverse that the auto-dismiss timer could cancel.
      expect(taps, 1);

      await tester.pumpAndSettle();
    });

    testWidgets('two fast taps open one chat, not two', (tester) async {
      var taps = 0;
      await showBanner(tester, onTap: () => taps++);

      await tester.tap(find.text(sender), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(find.text(sender), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(taps, 1);
    });
  });

  // ── The ✕ ──────────────────────────────────────────────────────────────────

  group('close button', () {
    testWidgets('dismisses immediately and never routes', (tester) async {
      var taps = 0;
      await showBanner(tester, onTap: () => taps++);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      expect(taps, 0);
      expect(NotificationBannerOverlay.isVisible, isFalse);
    });

    testWidgets('offers a 44pt touch target around a small glyph',
        (tester) async {
      await showBanner(tester);

      final target = tester.getSize(
        find
            .ancestor(
              of: find.byIcon(Icons.close_rounded),
              matching: find.byType(SizedBox),
            )
            .first,
      );
      // The old ✕ was a bare 18pt Icon with no padding: the tappable area was
      // the glyph itself.
      expect(target.width, greaterThanOrEqualTo(44));
      expect(target.height, greaterThanOrEqualTo(44));
      await closeBanner(tester);
    });
  });

  // ── Swipe ──────────────────────────────────────────────────────────────────

  group('swipe to dismiss', () {
    testWidgets('a swipe left past the threshold dismisses', (tester) async {
      var taps = 0;
      await showBanner(tester, onTap: () => taps++);

      await tester.drag(find.text(sender), const Offset(-300, 0));
      await tester.pumpAndSettle();

      expect(NotificationBannerOverlay.isVisible, isFalse);
      // A swipe is a dismissal, never a navigation.
      expect(taps, 0);
    });

    testWidgets('a swipe right past the threshold dismisses', (tester) async {
      await showBanner(tester);

      await tester.drag(find.text(sender), const Offset(300, 0));
      await tester.pumpAndSettle();

      expect(NotificationBannerOverlay.isVisible, isFalse);
    });

    testWidgets('the card follows the finger', (tester) async {
      await showBanner(tester);
      final rest = tester.getTopLeft(find.text(sender));

      final gesture =
          await tester.startGesture(tester.getCenter(find.text(sender)));
      await tester.pump();
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-90, 0));
      await tester.pump();

      // The old banner had no onUpdate at all: it never moved, at any point,
      // in any direction. THAT is what made it read as broken.
      expect(tester.getTopLeft(find.text(sender)).dx, lessThan(rest.dx - 80));

      await gesture.up();
      await tester.pumpAndSettle();
      await closeBanner(tester);
    });

    testWidgets('a short swipe springs back instead of dismissing',
        (tester) async {
      await showBanner(tester);
      final rest = tester.getTopLeft(find.text(sender));

      await tester.drag(find.text(sender), const Offset(-40, 0));
      await tester.pumpAndSettle();

      expect(NotificationBannerOverlay.isVisible, isTrue);
      expect(tester.getTopLeft(find.text(sender)), rest);
      await closeBanner(tester);
    });

    testWidgets('a fast flick dismisses even without much travel',
        (tester) async {
      await showBanner(tester);

      await tester.fling(find.text(sender), const Offset(-60, 0), 1600);
      await tester.pumpAndSettle();

      expect(NotificationBannerOverlay.isVisible, isFalse);
    });

    testWidgets('an upward drag still dismisses', (tester) async {
      await showBanner(tester);

      await tester.drag(find.text(sender), const Offset(0, -70));
      await tester.pumpAndSettle();

      expect(NotificationBannerOverlay.isVisible, isFalse);
    });

    testWidgets('a downward drag does not dismiss and does not run away',
        (tester) async {
      await showBanner(tester);
      final rest = tester.getTopLeft(find.text(sender));

      final gesture =
          await tester.startGesture(tester.getCenter(find.text(sender)));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 160));
      await tester.pump();

      // Rubber-banded: it gives a little, nowhere near the 200 it was pushed.
      final pulled = tester.getTopLeft(find.text(sender)).dy - rest.dy;
      expect(pulled, greaterThan(0));
      expect(pulled, lessThan(80));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(NotificationBannerOverlay.isVisible, isTrue);
      expect(tester.getTopLeft(find.text(sender)), rest);
      await closeBanner(tester);
    });
  });

  // ── Auto-dismiss and timer safety ──────────────────────────────────────────

  group('auto dismiss', () {
    testWidgets('leaves on its own after the display duration', (tester) async {
      await showBanner(tester, displayDuration: const Duration(seconds: 4));

      expect(NotificationBannerOverlay.isVisible, isTrue);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      expect(NotificationBannerOverlay.isVisible, isFalse);
    });

    testWidgets('touching the banner restarts the countdown', (tester) async {
      await showBanner(tester, displayDuration: const Duration(seconds: 4));

      await tester.pump(const Duration(milliseconds: 3000));
      await tester.drag(find.text(sender), const Offset(-30, 0)); // too short
      await tester.pumpAndSettle();

      // Under the old, unpausable timer this instant was past the deadline.
      await tester.pump(const Duration(milliseconds: 1500));
      expect(NotificationBannerOverlay.isVisible, isTrue);

      await tester.pump(const Duration(milliseconds: 3000));
      await tester.pumpAndSettle();
      expect(NotificationBannerOverlay.isVisible, isFalse);
    });

    testWidgets('a swipe cancels the timer — it cannot fire afterwards',
        (tester) async {
      await showBanner(tester, displayDuration: const Duration(seconds: 4));

      await tester.drag(find.text(sender), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(NotificationBannerOverlay.isVisible, isFalse);

      // If the timer had survived the swipe it would fire here, into a
      // disposed State. testWidgets fails the test if it is still pending.
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('tearing the tree down mid-animation leaves nothing pending',
        (tester) async {
      await showBanner(tester, displayDuration: const Duration(seconds: 4));

      await tester.tap(find.text(sender));
      await tester.pump(const Duration(milliseconds: 40)); // exit in flight
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump(const Duration(seconds: 6));
    });
  });

  // ── More than one message ──────────────────────────────────────────────────

  group('rapid messages', () {
    testWidgets('a second message replaces the first, one card on screen',
        (tester) async {
      await showBanner(tester, title: 'First Sender', body: 'one');
      await showBanner(tester,
          title: 'Second Sender', body: 'two', alreadyMounted: true);

      expect(find.text('First Sender'), findsNothing);
      expect(find.text('Second Sender'), findsOneWidget);
      await closeBanner(tester);
    });

    testWidgets(
        'the outgoing banner cannot take the incoming one down with it',
        (tester) async {
      await showBanner(tester, title: 'First Sender', body: 'one');

      // Start the first banner's exit, then let the second arrive INSIDE the
      // exit animation. This is the exact window in which the old static
      // `_dismiss` removed whichever entry happened to be current — which by
      // then was the new one.
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump(const Duration(milliseconds: 40));

      await showBanner(tester,
          title: 'Second Sender', body: 'two', alreadyMounted: true);

      // Well past the first banner's 220ms exit.
      await tester.pump(const Duration(milliseconds: 400));

      expect(NotificationBannerOverlay.isVisible, isTrue);
      expect(find.text('Second Sender'), findsOneWidget);
      await closeBanner(tester);
    });

    testWidgets('a swipe dismisses only the banner that was swiped',
        (tester) async {
      await showBanner(tester, title: 'First Sender', body: 'one');
      await tester.drag(find.text('First Sender'), const Offset(-300, 0));
      await tester.pump(const Duration(milliseconds: 40)); // fling in flight

      await showBanner(tester,
          title: 'Second Sender', body: 'two', alreadyMounted: true);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Second Sender'), findsOneWidget);
      expect(NotificationBannerOverlay.isVisible, isTrue);
      await closeBanner(tester);
    });
  });

  // ── Degradation ────────────────────────────────────────────────────────────

  testWidgets('no overlay means no banner, not an exception', (tester) async {
    // Deliberately NOT a MaterialApp: its Navigator brings an Overlay with
    // it, and the case being covered is the one where there is none to find.
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox.shrink(),
    ));
    final ctx = tester.element(find.byType(SizedBox));

    // A missing overlay must never throw on the notification path.
    NotificationBannerOverlay.show(
      context: ctx,
      overlay: null,
      title: sender,
      body: preview,
      type: 'chat_message',
    );
    await tester.pump();

    expect(NotificationBannerOverlay.isVisible, isFalse);
  });
}
