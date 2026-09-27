import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/app_notification.dart';
import 'package:help24/models/moderation.dart';
import 'package:help24/providers/auth_provider.dart';
import 'package:help24/services/account_status_service.dart';
import 'package:help24/services/session_scope.dart';
import 'package:help24/theme/app_theme.dart';
import 'package:help24/utils/error_mapper.dart';
import 'package:help24/widgets/account_restriction.dart';
import 'package:help24/widgets/report_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// TRUST & SAFETY, CLIENT SIDE.
///
/// The server is the enforcement (migrations 114–116, ModerationGuard). What
/// this suite pins is everything the app is responsible for: sending only
/// categories the database accepts, reading the person's own standing
/// correctly and failing OPEN when it cannot, explaining a restriction instead
/// of reporting it as a generic permission error, and never writing reports
/// straight into the table.

class _FakeAuth extends AuthProvider {
  _FakeAuth({this.uid = 'u_viewer'});
  final String uid;
  @override
  bool get isLoggedIn => uid.isNotEmpty;
  @override
  String? get currentUserId => uid;
  @override
  String get currentUserName => 'Viewer';
}

/// Shaped like the app's backend exceptions (JobsException and friends): a
/// server message and an HTTP status.
class _BackendError implements Exception {
  _BackendError(this.message, this.statusCode);
  final String message;
  final int statusCode;
  @override
  String toString() => 'BackendError($statusCode): $message';
}

Map<String, dynamic> _statusJson({
  String status = 'suspended',
  List<Map<String, dynamic>>? restrictions,
  List<String>? denied,
  List<Map<String, dynamic>> warnings = const [],
}) =>
    {
      'status': status,
      'restrictions': restrictions ??
          [
            {
              'id': '11111111-1111-4111-8111-111111111111',
              'kind': 'suspension',
              'reason': 'Repeated requests to pay outside Help24.',
              'starts_at': '2026-09-27T08:00:00Z',
              'ends_at': '2026-10-04T08:00:00Z',
              'reference': '11111111',
            },
          ],
      'denied_capabilities': denied ?? Capability.all,
      'warnings': warnings,
      'server_time': '2026-09-27T09:00:00Z',
    };

Future<void> _pumpHost(WidgetTester tester, Widget Function(BuildContext) body, {AuthProvider? auth}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AuthProvider>.value(
      value: auth ?? _FakeAuth(),
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(body: Builder(builder: body)),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AccountStatusStore.instance.resetForSignOut();
  });

  group('the report taxonomy matches the database', () {
    final fixture = jsonDecode(
      File('../supabase/tests/trust-safety/report_taxonomy.json').readAsStringSync(),
    ) as Map<String, dynamic>;

    test('every category the app offers is one the database accepts, and none is missing', () {
      expect(
        ReportCategory.values.map((c) => c.wire).toList(),
        List<String>.from(fixture['categories'] as List),
      );
    });

    test('each target offers exactly the database\'s list, in its order', () {
      final byTarget = fixture['by_target'] as Map<String, dynamic>;
      for (final target in ReportTargetType.values) {
        expect(
          ReportCategory.forTarget(target).map((c) => c.wire).toList(),
          List<String>.from(byTarget[target.wire] as List),
          reason: 'categories for ${target.wire}',
        );
      }
    });

    test('capabilities match moderation_capabilities()', () {
      expect(Capability.all, List<String>.from(fixture['capabilities'] as List));
    });
  });

  group('reading my own standing', () {
    test('a suspension parses with its reason, end, reference and denials', () {
      final s = AccountStatus.fromJson(_statusJson());
      expect(s.standing, AccountStanding.suspended);
      expect(s.restrictions.single.kind, RestrictionKind.suspension);
      expect(s.restrictions.single.reason, contains('outside Help24'));
      expect(s.restrictions.single.endsAt, DateTime.parse('2026-10-04T08:00:00Z').toLocal());
      expect(s.restrictions.single.reference, '11111111');
      expect(s.denies(Capability.post), isTrue);
      expect(s.denies(Capability.message), isTrue);
      expect(s.serverTime, isNotNull);
    });

    test('the most severe restriction explains a denial', () {
      final s = AccountStatus.fromJson(_statusJson(status: 'banned', restrictions: [
        {'id': 'r-msg', 'kind': 'messaging', 'reason': 'm', 'ends_at': null, 'reference': 'AAAA0001'},
        {'id': 'r-ban', 'kind': 'ban', 'reason': 'b', 'ends_at': null, 'reference': 'AAAA0002'},
      ]));
      expect(s.restrictionFor(Capability.message)?.id, 'r-ban');
      expect(s.primary?.kind, RestrictionKind.ban);
    });

    test('a partial restriction denies only its own capabilities', () {
      final s = AccountStatus.fromJson(_statusJson(
        status: 'restricted',
        restrictions: [
          {'id': 'r-m', 'kind': 'messaging', 'reason': 'Abusive messages.', 'ends_at': null, 'reference': 'BBBB0001'},
        ],
        denied: [Capability.message],
      ));
      expect(s.denies(Capability.message), isTrue);
      expect(s.denies(Capability.post), isFalse);
      expect(s.denies(Capability.apply), isFalse);
      expect(s.restrictionFor(Capability.message)?.kind, RestrictionKind.messaging);
    });

    test('an unreadable answer is UNKNOWN and denies nothing (fail open)', () {
      for (final raw in <Object?>[null, 'garbage', 42, {'status': 'unknown'}, <String, dynamic>{}]) {
        final s = AccountStatus.fromJson(raw);
        expect(s.isKnown, isFalse, reason: '$raw');
        for (final c in Capability.all) {
          expect(s.denies(c), isFalse, reason: '$raw must not deny $c');
        }
      }
    });

    test('malformed rows are skipped rather than crashing the screen', () {
      final s = AccountStatus.fromJson({
        ..._statusJson(),
        'restrictions': [
          {'id': '', 'kind': 'suspension'},
          {'id': 'x', 'kind': 'not_a_kind'},
          'nonsense',
        ],
        'warnings': 'not a list',
      });
      expect(s.restrictions, isEmpty);
      expect(s.warnings, isEmpty);
      expect(s.standing, AccountStanding.suspended);
    });
  });

  group('AccountStatusStore', () {
    test('its acknowledgement key is uid-scoped and purged with the session', () {
      expect(SessionScope.uidScopedPrefixes, contains(AccountStatusStore.ackPrefix));
    });

    test('a new restriction is explained once, then acknowledged per account', () async {
      final store = AccountStatusStore.instance;
      store.debugSet('u_1', AccountStatus.fromJson(_statusJson()));
      expect(store.unacknowledged?.id, '11111111-1111-4111-8111-111111111111');
      await store.acknowledge();
      expect(store.unacknowledged, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('help24_moderation_ack_u_1'), ['11111111-1111-4111-8111-111111111111']);
    });

    test('sign-out forgets the standing entirely', () {
      final store = AccountStatusStore.instance;
      store.debugSet('u_1', AccountStatus.fromJson(_statusJson()));
      expect(store.denies(Capability.post), isTrue);
      store.resetForSignOut();
      expect(store.uid, isNull);
      expect(store.status.isKnown, isFalse);
      expect(store.denies(Capability.post), isFalse);
    });
  });

  group('a restriction is explained, not reported as "no permission"', () {
    test('the database\'s refusal maps to the restriction, and refreshes the standing', () async {
      var refreshed = 0;
      ErrorMapper.onAccountRestricted = () => refreshed++;
      addTearDown(() => ErrorMapper.onAccountRestricted = null);

      final failure = ErrorMapper.toFailure(
        const PostgrestException(message: 'HELP24_ACCOUNT_RESTRICTED: suspended', code: '42501'),
      );
      expect(failure.title, 'Account suspended');
      expect(failure.message, contains('Account status'));
      await Future<void>.delayed(Duration.zero);
      expect(refreshed, 1);
    });

    test('the backend\'s 403 sentences map to the right restriction', () {
      expect(
        ErrorMapper.toFailure(_BackendError(
          'Your Help24 account has been banned. Open Account status in the app to see why and how to appeal.', 403)).title,
        'Account banned',
      );
      expect(
        ErrorMapper.toFailure(_BackendError(
          "Your Help24 account can't send messages right now. Open Account status in the app for details.", 403)).title,
        'Messaging restricted',
      );
      expect(
        ErrorMapper.toFailure(_BackendError(
          "Your Help24 account can't post, apply, hire or pay right now. Open Account status in the app for details.", 403)).title,
        'Account restricted',
      );
    });

    test('an ordinary permission error still reads as one', () {
      final failure = ErrorMapper.toFailure(
        const PostgrestException(message: 'new row violates row-level security policy', code: '42501'),
      );
      expect(failure.title, 'Not allowed');
    });

    test('booking a listing Help24 hid says so, not "provider already chosen"', () {
      final failure = ErrorMapper.toFailure(
        _BackendError('This listing was hidden by Help24 and can no longer be booked.', 409),
      );
      expect(failure.title, 'No longer available');
    });
  });

  group('the gate explains before the server refuses', () {
    testWidgets('a denied capability opens the explainer and stops', (tester) async {
      AccountStatusStore.instance.debugSet('u_viewer', AccountStatus.fromJson(_statusJson()));
      bool? allowed;
      await _pumpHost(tester, (context) => TextButton(
            onPressed: () => allowed = RestrictionGate.allows(context, Capability.post),
            child: const Text('Post'),
          ));
      await tester.tap(find.text('Post'));
      await tester.pumpAndSettle();
      expect(allowed, isFalse);
      expect(find.text('Account suspended'), findsOneWidget);
      expect(find.textContaining('outside Help24'), findsOneWidget);
      expect(find.text('View account status'), findsOneWidget);
      expect(find.text('11111111'), findsOneWidget);
    });

    testWidgets('an unknown standing never blocks', (tester) async {
      bool? allowed;
      await _pumpHost(tester, (context) => TextButton(
            onPressed: () => allowed = RestrictionGate.allows(context, Capability.message),
            child: const Text('Send'),
          ));
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(allowed, isTrue);
      expect(find.text('View account status'), findsNothing);
    });

    testWidgets('the shell banner appears only while restricted', (tester) async {
      await _pumpHost(tester, (_) => const AccountStatusBanner());
      expect(find.textContaining('Your account'), findsNothing);
      AccountStatusStore.instance.debugSet('u_viewer', AccountStatus.fromJson(_statusJson(
        status: 'banned',
        restrictions: [
          {'id': 'r-ban', 'kind': 'ban', 'reason': 'Fraud.', 'ends_at': null, 'reference': 'CCCC0001'},
        ],
      )));
      await tester.pump();
      expect(find.text('Your account has been banned'), findsOneWidget);
    });
  });

  group('the report sheet', () {
    testWidgets('offers the listing categories, and needs a reason before it can send', (tester) async {
      await _pumpHost(tester, (context) => TextButton(
            onPressed: () => ReportSheet.show(context, ReportTarget.post(postId: 'p-1', title: 'Fix my sink')),
            child: const Text('open'),
          ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Report'), findsOneWidget);
      expect(find.text('Tell us what went wrong. Reports are reviewed by the Help24 team.'), findsOneWidget);
      expect(find.text('Misleading service or request'), findsOneWidget);
      // Threats are about people, not listings.
      expect(find.text('Threats or intimidation'), findsNothing);

      FilledButton submit() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Submit Report'));
      expect(submit().onPressed, isNull, reason: 'no category chosen yet');

      await tester.ensureVisible(find.text('Other'));
      await tester.tap(find.text('Other'));
      await tester.pump();
      expect(submit().onPressed, isNull, reason: '"Other" needs a description');

      await tester.enterText(find.byType(TextField), 'The price changes after you pay the deposit.');
      await tester.pump();
      expect(submit().onPressed, isNotNull);
    });

    testWidgets('a threat shows the emergency line', (tester) async {
      await _pumpHost(tester, (context) => TextButton(
            onPressed: () => ReportSheet.show(context, ReportTarget.user(userId: 'u_x', name: 'Sam')),
            child: const Text('open'),
          ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Threats or intimidation'));
      await tester.pump();
      expect(find.textContaining('999 or 112'), findsOneWidget);
    });

    testWidgets('signed out, it asks for sign-in instead of opening', (tester) async {
      await _pumpHost(
        tester,
        (context) => TextButton(
          onPressed: () => ReportSheet.show(context, ReportTarget.user(userId: 'u_x', name: 'Sam')),
          child: const Text('open'),
        ),
        auth: _FakeAuth(uid: ''),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Tell us what went wrong. Reports are reviewed by the Help24 team.'), findsNothing);
    });

    test('the overflow menu names each target plainly', () {
      expect(ReportMenu.labelFor(ReportTarget.post(postId: 'p', title: 't')), 'Report this listing');
      expect(ReportMenu.labelFor(ReportTarget.user(userId: 'u', name: 'Sam')), 'Report Sam');
      expect(ReportMenu.labelFor(ReportTarget.application(applicationId: 'a', applicantName: 'Sam')), 'Report this application');
    });
  });

  group('account notifications', () {
    test('every moderation type is understood, and bans and suspensions are critical', () {
      for (final type in [
        'account_warning', 'account_suspended', 'account_banned', 'account_restricted',
        'account_restored', 'content_removed',
      ]) {
        expect(NotificationKind.of(type).category, NotificationCategory.account, reason: type);
      }
      expect(NotificationKind.of('account_banned').priority, NotificationPriority.critical);
      expect(NotificationKind.of('account_suspended').priority, NotificationPriority.critical);
      expect(NotificationKind.of('report_received').action, isNull,
          reason: 'a report receipt leads nowhere: outcomes are never shown to the reporter');
    });
  });

  group('source guards', () {
    String code(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

    test('the app never writes user_reports directly any more', () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        if (code(f.path).contains("from('user_reports')")) offenders.add(f.path);
      }
      expect(offenders, isEmpty,
          reason: 'reports go through POST /reports, where the reporter is the VERIFIED caller');
    });

    test('sending a chat message is gated, and the composer yields to the notice', () {
      final chat = code('lib/screens/messages_screen.dart');
      expect(chat.contains('RestrictionGate.allows(context, Capability.message)'), isTrue);
      expect(chat.contains('RestrictedComposerNotice()'), isTrue);
    });

    test('posting and applying are gated', () {
      expect(code('lib/screens/home_screen.dart').contains('RestrictionGate.allows(context, Capability.post)'), isTrue);
      expect(code('lib/widgets/post_flows.dart').contains('RestrictionGate.allows(context, Capability.apply)'), isTrue);
    });

    test('the store is registered with the session, and bound with the shell', () {
      expect(code('lib/main.dart').contains('SessionScope.instance.register(AccountStatusStore.instance)'), isTrue);
      expect(code('lib/screens/home_screen.dart').contains('AccountStatusStore.instance.bind(uid)'), isTrue);
    });
  });
}
