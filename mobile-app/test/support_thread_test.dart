import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/support_thread.dart';
import 'package:help24/providers/auth_provider.dart';
import 'package:help24/providers/connectivity_provider.dart';
import 'package:help24/screens/support_thread_screen.dart';
import 'package:help24/services/support_service.dart';
import 'package:provider/provider.dart';

/// MESSAGE HELP24: THE MEMBER'S CONVERSATION WITH HELP24.
///
/// A member writes from Profile → Message Help24; staff answer from the
/// dashboard Inbox and the answer arrives here with a notification. These
/// tests hold the parts that would hurt if they slipped: what is shown as
/// Help24's (never a staff name), that a message appears the moment it is
/// written, and that a failed send is kept and can be sent again without
/// being stored twice.

class _FakeAuth extends AuthProvider {
  _FakeAuth(this._uid);
  final String _uid;
  @override
  String? get currentUserId => _uid;
}

class _FakeApi implements SupportApi {
  _FakeApi(this.thread0);
  SupportThread thread0;
  bool failSends = false;
  final List<String> sentClientIds = [];
  final List<String> reads = [];

  @override
  Future<SupportThread> thread(String userId) async => thread0;

  @override
  Future<SupportMessage> send({required String userId, required String body, required String clientId}) async {
    sentClientIds.add(clientId);
    if (failSends) throw SupportException('Service unavailable', statusCode: 503);
    return SupportMessage(id: 'srv-${sentClientIds.length}', mine: true, body: body, createdAt: '2026-11-11T07:00:00Z');
  }

  @override
  Future<void> markRead(String userId) async => reads.add(userId);
}

Widget _app(SupportApi api) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => _FakeAuth('member-1')),
        ChangeNotifierProvider<ConnectivityProvider>(
          create: (_) => ConnectivityProvider(probeUrl: 'http://127.0.0.1:9/health', autoStart: false),
        ),
      ],
      child: MaterialApp(home: SupportThreadScreen(api: api)),
    );

void main() {
  group('the thread as the backend sends it', () {
    test('no conversation yet reads as an empty thread', () {
      final t = SupportThread.fromJson({'conversation': null, 'messages': [], 'unread': 0});
      expect(t.conversationId, isNull);
      expect(t.messages, isEmpty);
    });

    test('messages keep their order; only the member\'s own are "mine"', () {
      final t = SupportThread.fromJson({
        'conversation': {'id': 'c1', 'ref': 'H24-ABCDEF', 'status': 'waiting'},
        'messages': [
          {'id': 'm1', 'author': 'member', 'body': 'Hello', 'created_at': '2026-11-11T06:00:00Z'},
          {'id': 'm2', 'author': 'staff', 'body': 'Hi, how can we help?', 'created_at': '2026-11-11T06:05:00Z'},
        ],
        'unread': 1,
      });
      expect(t.ref, 'H24-ABCDEF');
      expect(t.messages.map((m) => m.mine), [true, false]);
      expect(t.unread, 1);
    });
  });

  group('the screen', () {
    testWidgets('a first visit explains what this is, and opening it marks answers read', (tester) async {
      final api = _FakeApi(SupportThread.empty);
      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();
      expect(find.text('Message Help24'), findsOneWidget);
      expect(find.textContaining('you get a notification'), findsOneWidget);
      expect(api.reads, ['member-1']);
    });

    testWidgets('Help24\'s answers are signed Help24 Support, never a staff name', (tester) async {
      final api = _FakeApi(SupportThread.fromJson({
        'conversation': {'id': 'c1', 'ref': 'H24-ABCDEF', 'status': 'waiting'},
        'messages': [
          {'id': 'm1', 'author': 'member', 'body': 'My payout is late', 'created_at': '2026-11-11T06:00:00Z'},
          {'id': 'm2', 'author': 'staff', 'body': 'It went out this morning.', 'created_at': '2026-11-11T06:05:00Z'},
        ],
        'unread': 1,
      }));
      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();
      expect(find.text('My payout is late'), findsOneWidget);
      expect(find.text('It went out this morning.'), findsOneWidget);
      // The app bar and the label above Help24's answer.
      expect(find.text('Help24 Support'), findsNWidgets(2));
    });

    testWidgets('a message shows at once; a failed one is kept and retried with the same id', (tester) async {
      final api = _FakeApi(SupportThread.empty)..failSends = true;
      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Can I change my number?');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(find.text('Can I change my number?'), findsOneWidget);
      expect(find.text('Not sent. Tap to try again.'), findsOneWidget);

      api.failSends = false;
      await tester.tap(find.text('Not sent. Tap to try again.'));
      await tester.pumpAndSettle();
      expect(find.text('Not sent. Tap to try again.'), findsNothing);
      expect(api.sentClientIds, hasLength(2));
      expect(api.sentClientIds.toSet(), hasLength(1), reason: 'a retry must reuse the client id, or it could be stored twice');
    });
  });
}
