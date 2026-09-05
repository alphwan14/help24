import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A NOTIFICATION TAP IS NEVER DROPPED BECAUSE THE SESSION IS STILL LOADING.
///
/// WHAT WENT WRONG
/// ---------------
/// Measured on a Galaxy S20+ (Android 13). Device B was killed with `am kill`,
/// Device A sent a chat message, the notification arrived correctly, and the
/// tap produced exactly this:
///
///     12:44:06.017  [LAUNCH] begin
///     12:44:06.200  [FCM][TAP] local notification tapped data={...chat_id...}
///     12:44:06.200  [NAV][NOTIFICATION_OPEN] type=chat_message chatId=b581d33d
///     12:44:06.200  [NAV][ROUTE_RESOLVED] type=chat_message
///     12:44:08.546  [LAUNCH] +2529ms handing over (feed ready)
///
/// `[NAV][OPEN_CHAT]` never followed, and the app settled on Discover. The
/// conversation was lost in silence.
///
/// There are two clocks. `AuthProvider` is constructed at ~+10ms and its
/// `initialize()` returns immediately because Firebase is not ready; nothing
/// re-runs it until `StartupGate` does, after the bootstrap future resolves at
/// ~+2.5s. The tap lands at +183ms — in between. `_routeNotification` opened
/// with a synchronous read of the provider's uid, got null for a user who was
/// signed in, and returned.
///
/// The second half of the same bug: `setupMessageHandlers` runs from
/// `initState`, before `Firebase.initializeApp()` completes. `onMessage` and
/// `onMessageOpenedApp` are static platform streams and attach fine, but
/// `FirebaseMessaging.instance` evaluates `Firebase.app()` and throws
/// `[core/no-app]` — so the `getInitialMessage()` call at the end of that try
/// block never ran, on any launch, on either device. `_handlersAttached` was
/// already true, so nothing could repair it later.
///
/// These are source guards for the same reason the rest of this suite uses
/// them (see system_bars_test.dart): the behaviour lives in private methods of
/// a private State class, and building the app in a unit test would pull
/// Firebase, Supabase and GoogleFonts over the network.
void main() {
  /// Source of a repo file with CRLF normalised and comments stripped.
  ///
  /// Comments are removed because several assertions below are of the form
  /// "this method must NOT mention X" — and the code now carries comments
  /// explaining precisely why X is absent. Prose naming the hazard must not
  /// read as the hazard.
  String code(String path) => File(path)
      .readAsStringSync()
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map((line) {
        final i = line.indexOf('//');
        return i == -1 ? line : line.substring(0, i);
      })
      .join('\n');

  /// The body of a 2-space-indented member starting at [needle], up to its
  /// closing brace. Enough to assert what one method does and does not do.
  ///
  /// The terminator is `}` ALONE on a line at two spaces. Searching for a bare
  /// `\n  }` instead would stop at the `  }) async {` that ends a multi-line
  /// parameter list, handing back the signature and nothing else — which reads
  /// as a passing "does not contain" assertion for every method here.
  String member(String src, String needle) {
    final start = src.indexOf(needle);
    expect(start, isNot(-1), reason: 'could not find `$needle`');
    final end = src.indexOf('\n  }\n', start);
    expect(end, isNot(-1), reason: 'no closing brace found for `$needle`');
    final body = src.substring(start, end);
    expect(body.contains('{'), isTrue,
        reason: 'extracted no body for `$needle` — the terminator moved');
    return body;
  }

  final mainSrc = code('lib/main.dart');
  final notifSrc = code('lib/services/notification_service.dart');

  group('the router waits for the session instead of assuming it', () {
    test('_routeNotification resolves the uid, it does not read it', () {
      final body = member(mainSrc, 'Future<void> _routeNotification(');
      expect(
        body.contains('await _routingUid(context)'),
        isTrue,
        reason: 'the uid must be RESOLVED. A bare read answers null for a '
            'signed-in user during the first ~2.5s of a cold launch, which is '
            'exactly when a notification tap arrives',
      );
      expect(
        body.contains('context.read<AuthProvider>().currentUserId'),
        isFalse,
        reason: 'reading the provider directly here is the defect: it returns '
            'null before StartupGate re-runs AuthProvider.initialize()',
      );
    });

    test('_routingUid waits on Firebase, not just on the provider', () {
      final body = member(mainSrc, 'Future<String?> _routingUid(');
      // The fast path: when the provider already knows, there is no await.
      expect(body.contains('context.read<AuthProvider>().currentUserId'), isTrue,
          reason: 'the warm case must stay synchronous — no added latency for '
              'a tap while the app is already running');
      // The slow path: Firebase is the earlier and more authoritative clock.
      expect(body.contains('AppFirebase.initialize()'), isTrue);
      expect(body.contains('_restoredUid()'), isTrue,
          reason: '_restoredUid is the bounded wait for the persisted session');
    });

    test('_openChat is given the uid and never re-reads it', () {
      expect(
        mainSrc.contains('Future<void> _openChat(BuildContext context, '
            'String chatId, String uid)'),
        isTrue,
        reason: 'the caller has already waited for the uid; re-reading the '
            'provider inside would re-introduce the same race one level down',
      );
      final body = member(mainSrc, 'Future<void> _openChat(');
      expect(body.contains('context.read<AuthProvider>()'), isFalse);
    });

    test('every _openChat call site passes a uid through', () {
      final calls = RegExp(r'await _openChat\(context, [^)]*\)')
          .allMatches(mainSrc)
          .map((m) => m.group(0)!)
          .toList();
      expect(calls, isNotEmpty, reason: 'no call sites found — did it move?');
      for (final call in calls) {
        expect(call.split(',').length, 3,
            reason: '`$call` must pass (context, chatId, uid)');
      }
    });
  });

  group('nothing touches FirebaseMessaging.instance before Firebase exists',
      () {
    test('setupMessageHandlers only attaches the static platform streams', () {
      final body = member(notifSrc, 'static void setupMessageHandlers(');
      expect(
        body.contains('FirebaseMessaging.instance'),
        isFalse,
        reason: 'this method runs from initState, BEFORE '
            'Firebase.initializeApp() resolves. That getter evaluates '
            'Firebase.app(), which throws [core/no-app] — and the catch below '
            'it swallowed the failure on every single launch',
      );
      // The two that legitimately work pre-init.
      expect(body.contains('FirebaseMessaging.onMessage'), isTrue);
      expect(body.contains('FirebaseMessaging.onMessageOpenedApp'), isTrue);
    });

    test('the launch-message check is only reachable once Firebase is ready',
        () {
      final launch =
          member(notifSrc, 'static Future<void> _deliverLaunchMessage(');
      expect(launch.contains('getInitialMessage()'), isTrue);

      // Exactly one call site in the file, and it is the one above.
      expect(
        RegExp('getInitialMessage').allMatches(notifSrc).length,
        1,
        reason: 'a second call site would likely sit back in a pre-Firebase '
            'path — which is the bug this file exists to prevent',
      );

      final init = member(notifSrc, 'static Future<void> initialize()');
      expect(init.contains('_deliverLaunchMessage()'), isTrue,
          reason: 'initialize() is the Firebase-ready path (it returns early '
              'unless AppFirebase.isReady), so the launch-message check '
              'belongs here');
    });

    test('initialize() still refuses to run before Firebase is ready', () {
      final init = member(notifSrc, 'static Future<void> initialize()');
      expect(init.contains('AppFirebase.isReady'), isTrue,
          reason: 'that guard is what makes initialize() a safe home for the '
              'launch-message check in the first place');
    });
  });
}
