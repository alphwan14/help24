import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/chat_person.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/providers/connectivity_provider.dart';
import 'package:help24/services/chat_store.dart';
import 'package:help24/services/chat_sync.dart';
import 'package:help24/services/delivery_receipts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/chat_store_harness.dart';

/// THE SYNC LAYER: the network only WRITES the chat database.
///
/// Driven through [ChatSync.transport], so each test is a scripted server:
/// pages of rows, a profile read that answers or fails, thread pages.
const me = 'uid-me';

class _Server {
  final List<ChatRowSnapshot> rows = [];
  final Map<String, ChatPerson> people = {};
  bool profilesFail = false;
  bool rowsFail = false;
  final List<({int limit, int offset})> rowCalls = [];
  final List<Set<String>> profileCalls = [];
  final List<String> threadCalls = [];
  final Map<String, List<Message>> threads = {};

  ChatSyncTransport get transport => ChatSyncTransport(
        fetchRows: (String who, {int limit = 50, int offset = 0}) async {
          rowCalls.add((limit: limit, offset: offset));
          if (rowsFail) throw const SocketException('Failed host lookup');
          final sorted = [...rows]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
          return sorted.skip(offset).take(limit).toList();
        },
        fetchProfiles: (Iterable<String> ids) async {
          profileCalls.add(ids.toSet());
          if (profilesFail) {
            // Exactly the device trace: chats answered, users did not.
            throw const SocketException("Failed host lookup: 'taohzhnvaitrpxcyjflq.supabase.co'");
          }
          return {for (final id in ids) if (people[id] != null) id: people[id]!};
        },
        fetchThread: (String chatId, String who, {int limit = 50}) async {
          threadCalls.add(chatId);
          return threads[chatId] ?? const [];
        },
      );
}

ChatRowSnapshot row(String id, String participant, DateTime at, {String last = 'hi', int unread = 0}) =>
    ChatRowSnapshot(
      id: id,
      participantId: participant,
      lastMessage: last,
      updatedAt: at,
      serverUpdatedAt: at.toIso8601String(),
      unreadCount: unread,
    );

Message msg(String id, String chat, DateTime at) => Message(
      id: id,
      conversationId: chat,
      senderId: 'p',
      text: id,
      timestamp: at,
      isMe: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _Server server;
  final store = ChatStore.instance;
  final sync = ChatSync.instance;

  Future<void> runSync() async {
    await sync.syncNow();
    await sync.backgroundWork;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await useTestChatStore();
    NetworkHealth.resetForTest();
    DeliveryReceipts.resetForTest();
    DeliveryReceipts.writeOverride = (_, __, ___) async {};
    server = _Server();
    ChatSync.transport = server.transport;
    sync.attachForTest(me);
  });

  tearDown(() async {
    sync.stop();
    ChatSync.transport = const ChatSyncTransport();
    DeliveryReceipts.resetForTest();
    await disposeTestChatStore(dir);
  });

  group('the "?" bug, at the layer that caused it', () {
    test('a sync whose profile read fails stores rows and KEEPS names', () async {
      server.rows.add(row('c1', 'p1', DateTime.utc(2026, 10, 5)));
      server.people['p1'] = const ChatPerson(id: 'p1', name: 'Alphonse Lincoln');
      await runSync();
      expect((await store.loadConversations(me)).single.userName, 'Alphonse Lincoln');

      // Offline, then back: the reconnect re-fetch. A new session reads every
      // profile again — and this time the users read fails.
      sync.newSessionForTest();
      server.rows
        ..clear()
        ..add(row('c1', 'p1', DateTime.utc(2026, 10, 9), last: 'Dud'));
      server.profilesFail = true;
      await runSync();

      final c = (await store.loadConversations(me)).single;
      expect(c.userName, 'Alphonse Lincoln');
      expect(c.lastMessage, 'Dud');
      expect(sync.phase.value, ChatSyncPhase.idle, reason: 'the list did sync');
    });

    test('a person never named is retried on the next sync, not forever re-read', () async {
      server.rows.add(row('c1', 'p1', DateTime.utc(2026, 10, 5)));
      server.profilesFail = true;
      await runSync();
      expect((await store.loadConversations(me)).single.userName, isEmpty);

      server.profilesFail = false;
      server.people['p1'] = const ChatPerson(id: 'p1', name: 'Pauline Oyombe');
      await runSync();
      expect((await store.loadConversations(me)).single.userName, 'Pauline Oyombe');

      // Known now: the same session does not ask about them again.
      server.profileCalls.clear();
      await runSync();
      expect(server.profileCalls, isEmpty);
    });
  });

  group('incremental sync', () {
    test('a first sync pages through the whole list', () async {
      for (var i = 0; i < 120; i++) {
        server.rows.add(row('c$i', 'p$i', DateTime.utc(2026, 1, 1).add(Duration(hours: i))));
      }
      await runSync();
      expect(await store.loadConversations(me), hasLength(120));
      expect(server.rowCalls.map((c) => c.offset), [0, 50, 100]);
      expect(await store.syncValue(me, 'conversations_cursor'),
          DateTime.utc(2026, 1, 1).add(const Duration(hours: 119)).toIso8601String());
    });

    test('later syncs read the head page and stop at the cursor', () async {
      for (var i = 0; i < 120; i++) {
        server.rows.add(row('c$i', 'p$i', DateTime.utc(2026, 1, 1).add(Duration(hours: i))));
      }
      await runSync();
      server.rowCalls.clear();
      // One conversation moves to the top.
      server.rows[3] = row('c3', 'p3', DateTime.utc(2026, 3, 1), last: 'new message');
      await runSync();
      expect(server.rowCalls, hasLength(1), reason: 'caught up within the head page');
      expect(server.rowCalls.single.limit, 30);
      final list = await store.loadConversations(me);
      expect(list.first.id, 'c3');
      expect(list.first.lastMessage, 'new message');
      expect(list, hasLength(120), reason: 'nothing is lost by reading less');
    });

    test('after a long time offline it pages until it reaches what it had', () async {
      for (var i = 0; i < 10; i++) {
        server.rows.add(row('old$i', 'p$i', DateTime.utc(2026, 1, 1, i)));
      }
      await runSync();
      server.rowCalls.clear();
      for (var i = 0; i < 70; i++) {
        server.rows.add(row('new$i', 'q$i', DateTime.utc(2026, 5, 1).add(Duration(minutes: i))));
      }
      await runSync();
      // Head page of 30, then pages of 50 until a row is no newer than the
      // cursor: the second page reaches the old rows and stops.
      expect(server.rowCalls.map((c) => c.offset), [0, 30]);
      expect(await store.loadConversations(me), hasLength(80));
    });
  });

  group('an error is not an emptiness', () {
    test('a failed first load with nothing stored is reported', () async {
      server.rowsFail = true;
      await runSync();
      expect(sync.firstLoadError.value, isNotNull);
      expect(await store.loadConversations(me), isEmpty);
    });

    test('a failed sync with a stored list changes nothing and reports nothing', () async {
      server.rows.add(row('c1', 'p1', DateTime.utc(2026, 10, 5)));
      await runSync();
      server.rowsFail = true;
      await runSync();
      expect(sync.firstLoadError.value, isNull);
      expect(await store.loadConversations(me), hasLength(1));
      expect(sync.phase.value, ChatSyncPhase.connecting, reason: 'online, not yet in touch');
    });

    test('offline is a status: no request, phase says so', () async {
      NetworkHealth.publish(offline: true);
      await runSync();
      expect(server.rowCalls, isEmpty);
      expect(sync.phase.value, ChatSyncPhase.offline);
      NetworkHealth.publish(offline: false);
    });
  });

  group('prefetch while online, so offline is useful', () {
    test('the 30 most recent threads, 50 messages each, once', () async {
      for (var i = 0; i < 40; i++) {
        final at = DateTime.utc(2026, 1, 1).add(Duration(hours: i));
        server.rows.add(row('c$i', 'p$i', at));
        server.threads['c$i'] = [for (var m = 0; m < 50; m++) msg('c$i-$m', 'c$i', at.subtract(Duration(minutes: m)))];
      }
      await runSync();
      expect(server.threadCalls, hasLength(30));
      expect(server.threadCalls.first, 'c39', reason: 'most recent first');
      expect(server.threadCalls, isNot(contains('c0')));
      expect(await store.loadThread(me, 'c39'), hasLength(50));

      // The per-session budget bug cannot come back: a second sync with
      // nothing new fetches NO thread, however often the list syncs.
      server.threadCalls.clear();
      await runSync();
      await runSync();
      expect(server.threadCalls, isEmpty);

      // One conversation moves: exactly that thread is fetched.
      server.rows[39] = row('c39', 'p39', DateTime.utc(2026, 6, 1), last: 'new');
      await runSync();
      expect(server.threadCalls, ['c39']);
    });

    test('a push fetches its thread first, even when not stale', () async {
      server.rows.add(row('c1', 'p1', DateTime.utc(2026, 10, 5)));
      server.threads['c1'] = [msg('m1', 'c1', DateTime.utc(2026, 10, 5))];
      await runSync();
      server.threadCalls.clear();
      sync.onPush('c1');
      for (var i = 0; i < 100 && !server.threadCalls.contains('c1'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(server.threadCalls, ['c1']);
    });
  });
}
