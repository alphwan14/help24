import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/chat_person.dart';
import 'package:help24/providers/app_provider.dart';
import 'package:help24/providers/connectivity_provider.dart';
import 'package:help24/services/chat_push_ingest.dart';
import 'package:help24/services/chat_store.dart';
import 'package:help24/services/chat_sync.dart';
import 'package:help24/theme/app_icons.dart';
import 'package:help24/widgets/chat/chat_chrome.dart';
import 'package:help24/widgets/chat/chat_sync_status.dart';
import 'package:help24/widgets/chat/person_avatar.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/chat_store_harness.dart';

/// Chats open fully offline, even after the app is killed: the pieces around
/// the database — the cold-start read, the background push write, and what
/// the screens draw when a name or a network is missing.
const me = 'uid-me';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final store = ChatStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await useTestChatStore();
    NetworkHealth.resetForTest();
  });
  tearDown(() async {
    ChatSync.instance.stop();
    NetworkHealth.resetForTest();
    await disposeTestChatStore(dir);
  });

  group('cold start reads the database before anything else', () {
    test('offline: the whole list, named, with no request and no skeleton', () async {
      await store.applyConversationSync(me, rows: [
        ChatRowSnapshot(
          id: 'c1',
          participantId: 'p1',
          lastMessage: 'Dud',
          updatedAt: DateTime.utc(2026, 10, 5),
          serverUpdatedAt: '2026-10-05T00:00:00Z',
          unreadCount: 2,
          postTitle: 'Shambala boy',
          postId: 'post-1',
        ),
      ], people: {'p1': const ChatPerson(id: 'p1', name: 'Alphonse Lincoln')});
      await restartChatStore(); // the app was killed
      NetworkHealth.publish(offline: true); // airplane mode

      final provider = AppProvider();
      await provider.loadConversations(me);
      final c = provider.conversations.single;
      expect(c.userName, 'Alphonse Lincoln');
      expect(c.lastMessage, 'Dud');
      expect(c.unreadCount, 2);
      expect(c.postTitle, 'Shambala boy');
      expect(provider.isLoadingConversations, isFalse);
      expect(provider.messagesError, isNull, reason: 'offline is a status, not an error');
      expect(ChatSync.instance.phase.value, ChatSyncPhase.offline);
      provider.dispose();
    });

    test('a fresh install offline has nothing to show — and says so, not "?"', () async {
      NetworkHealth.publish(offline: true);
      final provider = AppProvider();
      await provider.loadConversations(me);
      expect(provider.conversations, isEmpty);
      expect(provider.isLoadingConversations, isFalse, reason: 'no skeleton for a load that cannot happen');
      final screen = File('lib/screens/messages_screen.dart').readAsStringSync();
      expect(screen, contains('Connect to the internet to load your chats'));
      provider.dispose();
    });

    test('a write by anyone repaints the list from the database', () async {
      final provider = AppProvider();
      NetworkHealth.publish(offline: true);
      await provider.loadConversations(me);
      expect(provider.conversations, isEmpty);
      await store.applyConversationSync(me, rows: [
        ChatRowSnapshot(
          id: 'c9',
          participantId: 'p9',
          lastMessage: 'pushed',
          updatedAt: DateTime.utc(2026, 10, 9),
          serverUpdatedAt: '2026-10-09T00:00:00Z',
          unreadCount: 1,
        ),
      ], people: const {});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(provider.conversations.single.lastMessage, 'pushed');
      provider.dispose();
    });
  });

  group('a push received while the app is killed lands in the database', () {
    test('chat row, latest messages and an unknown sender, in one go', () async {
      final requested = <Uri>[];
      final client = MockClient((req) async {
        requested.add(req.url);
        expect(req.headers['Authorization'], 'Bearer jwt-1');
        final path = req.url.path;
        if (path.endsWith('/rest/v1/chats')) {
          return http.Response(
            jsonEncode([
              {
                'id': 'c1',
                'user1': 'p1',
                'user2': me,
                'post_id': 'post-1',
                'posts': {'title': 'Emergency Dog Trainer'},
                'last_message': 'On my way',
                'updated_at': '2026-10-09T10:19:00+00:00',
                'user1_unread_count': 0,
                'user2_unread_count': 3,
              },
            ]),
            200,
          );
        }
        if (path.endsWith('/rest/v1/chat_messages')) {
          return http.Response(
            jsonEncode([
              {
                'id': '11111111-1111-4111-8111-111111111111',
                'chat_id': 'c1',
                'sender_id': 'p1',
                'content': 'On my way',
                'type': 'text',
                'status': 'sent',
                'created_at': '2026-10-09T10:19:00+00:00',
              },
            ]),
            200,
          );
        }
        if (path.endsWith('/rest/v1/users')) {
          return http.Response(
            jsonEncode([
              {'id': 'p1', 'name': 'Alphonse Lincoln', 'avatar_url': 'https://x/a.jpg'},
            ]),
            200,
          );
        }
        return http.Response('[]', 404);
      });

      await ChatPushIngest.ingest(
        'c1',
        session: Future.value((uid: me, jwt: 'jwt-1')),
        client: client,
      );

      await restartChatStore(); // next launch, offline
      final c = (await store.loadConversations(me)).single;
      expect(c.userName, 'Alphonse Lincoln');
      expect(c.lastMessage, 'On my way');
      expect(c.unreadCount, 3, reason: "the viewer's own unread column");
      expect(c.postTitle, 'Emergency Dog Trainer');
      expect((await store.loadThread(me, 'c1')).single.text, 'On my way');
      expect(await store.syncValue(me, 'conversations_cursor'), isNull,
          reason: 'one chat must not move the list cursor');
      final select = requested.first.queryParameters['select'];
      expect(select, '*,posts!chats_post_id_fkey(title)');
    });

    test('no session (signed out, refused exchange): nothing is written', () async {
      final client = MockClient((_) async => fail('no request without a session'));
      await ChatPushIngest.ingest('c1', session: Future.value(null), client: client);
      expect(await store.loadConversations(me), isEmpty);
    });

    test('a server error is swallowed — the notification must still show', () async {
      final client = MockClient((_) async => http.Response('boom', 503));
      await ChatPushIngest.ingest('c1', session: Future.value((uid: me, jwt: 'j')), client: client);
      expect(await store.loadConversations(me), isEmpty);
    });
  });

  group('never "?" for a person', () {
    Widget host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

    testWidgets('initials on the person\'s own tint', (tester) async {
      await tester.pumpWidget(host(const PersonAvatar(userId: 'p1', name: 'Alphonse Lincoln', size: 52)));
      expect(find.text('AL'), findsOneWidget);
      expect(find.text('?'), findsNothing);
    });

    testWidgets('no name known: a person glyph, not a question mark', (tester) async {
      await tester.pumpWidget(host(const PersonAvatar(userId: 'p1', name: '', size: 52)));
      expect(find.byIcon(AppIcons.person), findsOneWidget);
      expect(find.text('?'), findsNothing);
    });

    testWidgets('a missing photo file falls back, never a broken circle', (tester) async {
      await tester.pumpWidget(host(const PersonAvatar(
        userId: 'p1',
        name: 'Pauline Oyombe',
        size: 52,
        avatarPath: '/no/such/file.png',
      )));
      // The file read is real I/O: let it fail outside the fake clock.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(find.text('PO'), findsOneWidget);
    });

    testWidgets('the chat header names an unknown person in words', (tester) async {
      await tester.pumpWidget(host(ChatHeader(
        name: ChatPeople.displayName(''),
        avatarUrl: '',
        onBack: () {},
        menu: const SizedBox(),
      )));
      expect(find.text(ChatPeople.unknownName), findsOneWidget);
      expect(find.text('?'), findsNothing);
    });

    test('no chat surface writes "?" as a name any more (source guard)', () {
      for (final path in const [
        'lib/services/chat_service_supabase.dart',
        'lib/services/chat_store.dart',
        'lib/services/chat_sync.dart',
        'lib/services/chat_push_ingest.dart',
        'lib/screens/messages_screen.dart',
        'lib/widgets/chat/chat_chrome.dart',
        'lib/widgets/chat/person_avatar.dart',
      ]) {
        final code = File(path)
            .readAsLinesSync()
            .where((l) => !l.trimLeft().startsWith('//'))
            // SQL placeholders are question marks too, and are not names.
            .where((l) => !l.contains('List.filled('))
            .join('\n');
        expect(code.contains("'?'"), isFalse, reason: path);
      }
    });
  });

  group('offline is a status line, not an error', () {
    Widget host(ValueNotifier<ChatSyncPhase> phase) =>
        MaterialApp(home: Scaffold(body: ChatSyncStatusLine(phase: phase)));

    testWidgets('"Waiting for network" shows at once', (tester) async {
      final phase = ValueNotifier(ChatSyncPhase.offline);
      await tester.pumpWidget(host(phase));
      expect(find.text('Waiting for network'), findsOneWidget);
    });

    testWidgets('"Connecting…" only if it lasts, then nothing once in sync', (tester) async {
      final phase = ValueNotifier(ChatSyncPhase.idle);
      await tester.pumpWidget(host(phase));
      expect(find.byType(Text), findsNothing);

      phase.value = ChatSyncPhase.connecting;
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Connecting…'), findsNothing, reason: 'a healthy sync is not announced');
      await tester.pump(chatConnectingGrace);
      expect(find.text('Connecting…'), findsOneWidget);

      phase.value = ChatSyncPhase.idle;
      await tester.pumpAndSettle();
      expect(find.text('Connecting…'), findsNothing);
    });

    testWidgets('both themes', (tester) async {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(body: ChatSyncStatusLine(phase: ValueNotifier(ChatSyncPhase.offline))),
        ));
        expect(find.text('Waiting for network'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  });
}
