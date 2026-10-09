import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/chat_person.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/services/cache_service.dart';
import 'package:help24/services/chat_store.dart';
import 'package:help24/services/session_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/chat_store_harness.dart';

/// THE CHAT DATABASE — the local source of truth every chat screen reads.
///
/// The bug these lock down, reproduced on the S20+ (2026-10-09): a reconnect
/// re-fetch whose `chats` read succeeded and whose `users` read failed with
/// "Failed host lookup" stored every participant's name as "?", over the names
/// the phone already had. The next offline launch showed a Messages tab of
/// question marks. The store now keeps people as people, writes a name only
/// when it is known, and imports the old cache without the poison.
const me = 'uid-me';

ChatRowSnapshot row(
  String id, {
  String participant = 'p1',
  String last = 'hello',
  DateTime? at,
  int unread = 0,
  String? postId,
  String? postTitle,
}) {
  final t = at ?? DateTime.utc(2026, 10, 5, 9);
  return ChatRowSnapshot(
    id: id,
    participantId: participant,
    lastMessage: last,
    updatedAt: t,
    serverUpdatedAt: t.toIso8601String(),
    unreadCount: unread,
    postId: postId,
    postTitle: postTitle,
  );
}

Message msg(
  String id, {
  String chat = 'c1',
  String sender = 'p1',
  String text = 'hi',
  DateTime? at,
  String status = 'sent',
}) =>
    Message(
      id: id,
      conversationId: chat,
      senderId: sender,
      text: text,
      timestamp: at ?? DateTime.utc(2026, 10, 5, 9),
      isMe: sender == me,
      status: status,
    );

void main() {
  late Directory dir;
  final store = ChatStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await useTestChatStore();
  });
  tearDown(() => disposeTestChatStore(dir));

  group('people — a known name is never lost, "?" is never stored', () {
    test('a sync with people stores their names and photos', () async {
      await store.applyConversationSync(me,
          rows: [row('c1', participant: 'p1')],
          people: {
            'p1': const ChatPerson(id: 'p1', name: 'Alphonse Lincoln', avatarUrl: 'https://x/a.jpg'),
          });
      final list = await store.loadConversations(me);
      expect(list.single.userName, 'Alphonse Lincoln');
      expect(list.single.userAvatar, 'https://x/a.jpg');
    });

    test('THE BUG: a later sync whose profile read FAILED keeps every name', () async {
      await store.applyConversationSync(me,
          rows: [row('c1', participant: 'p1'), row('c2', participant: 'p2')],
          people: {
            'p1': const ChatPerson(id: 'p1', name: 'Alphonse Lincoln'),
            'p2': const ChatPerson(id: 'p2', name: 'Pauline Oyombe'),
          });
      // The reconnect re-fetch: rows came back (newer message), people did not.
      await store.applyConversationSync(me,
          rows: [
            row('c1', participant: 'p1', last: 'newer', at: DateTime.utc(2026, 10, 9)),
            row('c2', participant: 'p2'),
          ],
          people: const {});
      await restartChatStore(); // the offline relaunch
      final list = await store.loadConversations(me);
      expect(list.map((c) => c.userName), ['Alphonse Lincoln', 'Pauline Oyombe']);
      expect(list.first.lastMessage, 'newer', reason: 'the rows themselves are still applied');
      expect(list.map((c) => c.userName), isNot(contains('?')));
    });

    test('"?" from any source is refused as a name', () async {
      await store.applyConversationSync(me,
          rows: [row('c1')], people: {'p1': const ChatPerson(id: 'p1', name: 'Pauline')});
      await store.upsertPeople(me, [const ChatPerson(id: 'p1', name: '?')]);
      await store.upsertConversation(
        me,
        Conversation(
          id: 'c1',
          participantId: 'p1',
          userName: '?',
          lastMessage: 'x',
          lastMessageTime: DateTime.utc(2026),
        ),
      );
      expect((await store.loadConversations(me)).single.userName, 'Pauline');
      expect((await store.person(me, 'p1'))!.name, 'Pauline');
    });

    test('the conversation keeps its own copy of the name as a fallback', () async {
      await store.upsertConversation(
        me,
        Conversation(
          id: 'c1',
          participantId: 'p9',
          userName: 'Babel Damien',
          lastMessage: 'Ww hii',
          lastMessageTime: DateTime.utc(2026, 7, 25),
        ),
      );
      // No users row for p9 at all — the list still has a name.
      expect(await store.person(me, 'p9'), isNull);
      expect((await store.loadConversations(me)).single.userName, 'Babel Damien');
    });

    test('a person nobody could name is unknown — and renders as words', () async {
      await store.applyConversationSync(me, rows: [row('c1', participant: 'ghost')], people: const {});
      final c = (await store.loadConversations(me)).single;
      expect(c.userName, isEmpty);
      expect(ChatPeople.displayName(c.userName), ChatPeople.unknownName);
      expect(ChatPeople.initials(c.userName), isEmpty, reason: 'a glyph, not invented letters');
    });

    test('a profile read that says "no photo" clears the old photo', () async {
      await store.applyConversationSync(me,
          rows: [row('c1')], people: {'p1': const ChatPerson(id: 'p1', name: 'A', avatarUrl: 'https://x/1.jpg')});
      await store.applyConversationSync(me,
          rows: [row('c1')], people: {'p1': const ChatPerson(id: 'p1', name: 'A')});
      expect((await store.loadConversations(me)).single.userAvatar, isEmpty);
    });
  });

  group('the name fallback', () {
    test('displayName is never empty and never "?"', () {
      for (final name in [null, '', '   ', '?', ' ? ']) {
        expect(ChatPeople.displayName(name), ChatPeople.unknownName);
      }
      expect(ChatPeople.displayName('  Pauline Oyombe '), 'Pauline Oyombe');
    });

    test('initials come from a known name only', () {
      expect(ChatPeople.initials('Alphonse Lincoln'), 'AL');
      expect(ChatPeople.initials('pauline'), 'P');
      expect(ChatPeople.initials('Mary Wanjiku Otieno'), 'MO');
      expect(ChatPeople.initials('?'), isEmpty);
    });

    test('a person keeps one tint, on every launch', () {
      // FNV-1a, not String.hashCode (which is not stable across runs).
      expect(ChatPeople.tintIndex('nlAJnbHFktNTYEGPPPrBE1zu0RB2'),
          ChatPeople.tintIndex('nlAJnbHFktNTYEGPPPrBE1zu0RB2'));
      expect(ChatPeople.tintIndex('a'), 0xe40c292c);
      final spread = {for (var i = 0; i < 64; i++) ChatPeople.tintIndex('user-$i') % 8};
      expect(spread.length, greaterThan(4), reason: 'people are told apart');
    });
  });

  group('conversations', () {
    test('most recent first, with unread counts and post titles', () async {
      await store.applyConversationSync(me, rows: [
        row('old', at: DateTime.utc(2026, 6, 15)),
        row('new', at: DateTime.utc(2026, 10, 5), unread: 2, postId: 'post-1', postTitle: 'Shambala boy'),
      ], people: const {});
      final list = await store.loadConversations(me);
      expect(list.map((c) => c.id), ['new', 'old']);
      expect(list.first.unreadCount, 2);
      expect(list.first.postTitle, 'Shambala boy');
    });

    test('a read badge stays at zero across a restart', () async {
      await store.applyConversationSync(me, rows: [row('c1', unread: 3)], people: const {});
      await store.markRead(me, 'c1');
      await restartChatStore();
      expect((await store.loadConversations(me)).single.unreadCount, 0);
    });

    test('a row built on the send path never rolls back a newer preview', () async {
      await store.applyConversationSync(me,
          rows: [row('c1', last: 'newest', at: DateTime.utc(2026, 10, 9), unread: 1)], people: const {});
      await store.upsertConversation(
        me,
        Conversation(
          id: 'c1',
          participantId: 'p1',
          userName: 'Known',
          lastMessage: 'stale',
          lastMessageTime: DateTime.utc(2026, 1, 1),
          unreadCount: 0,
        ),
      );
      final c = (await store.loadConversations(me)).single;
      expect(c.lastMessage, 'newest');
      expect(c.lastMessageTime, DateTime.utc(2026, 10, 9));
      expect(c.userName, 'Known', reason: 'a known name is still taken');
    });

    test('the cursor is the newest updated_at seen, and only a list sync moves it', () async {
      await store.applyConversationSync(me, rows: [row('c1')], people: const {}, cursor: '2026-10-05T09:00:00Z');
      await store.applyConversationSync(me, rows: [row('c2')], people: const {});
      expect(await store.syncValue(me, 'conversations_cursor'), '2026-10-05T09:00:00Z');
    });

    test('lookup by identity: post_id = X and post_id IS NULL are different chats', () async {
      await store.applyConversationSync(me, rows: [
        row('general', participant: 'p1', at: DateTime.utc(2026, 9, 1)),
        row('scoped', participant: 'p1', postId: 'post-1', at: DateTime.utc(2026, 10, 1)),
      ], people: const {});
      expect((await store.findConversationFor(me, 'p1'))!.id, 'general');
      expect((await store.findConversationFor(me, 'p1', postId: 'post-1'))!.id, 'scoped');
      expect(await store.findConversationFor(me, 'p1', postId: 'post-2'), isNull);
      expect((await store.findConversationFor(me, 'p1', mostRecent: true))!.id, 'scoped');
    });

    test('a thread is stale until fetched, and again once its chat moves', () async {
      await store.applyConversationSync(me, rows: [row('c1', at: DateTime.utc(2026, 10, 5))], people: const {});
      var c = (await store.recentThreads(me)).single;
      expect(c.isStale, isTrue);
      await store.setThreadSynced(me, 'c1', c.lastMessageAt);
      expect((await store.recentThreads(me)).single.isStale, isFalse);
      await store.applyConversationSync(me, rows: [row('c1', at: DateTime.utc(2026, 10, 6))], people: const {});
      c = (await store.recentThreads(me)).single;
      expect(c.isStale, isTrue);
    });

    test('the pinned job bar snapshot survives a restart', () async {
      await store.applyConversationSync(me, rows: [row('c1')], people: const {});
      await store.saveJobSnapshot(me, 'c1', {
        'lifecycle': {'stage': 'paid'},
        'post': {'id': 'post-1', 'price': 1500},
      });
      await restartChatStore();
      final snap = await store.jobSnapshot(me, 'c1');
      expect(snap!['lifecycle'], {'stage': 'paid'});
      expect((snap['post'] as Map)['price'], 1500);
    });
  });

  group('messages', () {
    test('every field a bubble renders round-trips through the database', () async {
      final full = Message(
        id: 'm1',
        conversationId: 'c1',
        senderId: me,
        text: 'Wild Waters',
        timestamp: DateTime.utc(2026, 7, 23, 20, 27, 5),
        isMe: true,
        type: 'location',
        latitude: -4.0435,
        longitude: 39.6682,
        liveUntil: DateTime.utc(2026, 7, 23, 21),
        attachmentUrl: 'chat-attachments/c1/m1.jpg',
        status: 'seen',
        seenAt: DateTime.utc(2026, 7, 23, 20, 30),
        deliveredAt: DateTime.utc(2026, 7, 23, 20, 28),
        deletedForEveryone: true,
        replyToId: 'm0',
        replyToSender: 'Pauline',
        replyToPreview: 'where?',
      );
      await store.upsertMessages(me, 'c1', [full]);
      await restartChatStore();
      final m = (await store.loadThread(me, 'c1')).single;
      expect(m.id, 'm1');
      expect(m.conversationId, 'c1');
      expect(m.isMe, isTrue);
      expect(m.text, 'Wild Waters');
      expect(m.timestamp, full.timestamp);
      expect(m.type, 'location');
      expect(m.latitude, -4.0435);
      expect(m.longitude, 39.6682);
      expect(m.liveUntil, full.liveUntil);
      expect(m.attachmentUrl, full.attachmentUrl);
      expect(m.status, 'seen');
      expect(m.seenAt, full.seenAt);
      expect(m.deliveredAt, full.deliveredAt);
      expect(m.deletedForEveryone, isTrue);
      expect(m.replyToId, 'm0');
      expect(m.replyToSender, 'Pauline');
      expect(m.replyToPreview, 'where?');
    });

    test('upsert by id: a redelivered message updates in place, never twice', () async {
      await store.upsertMessages(me, 'c1', [msg('m1', status: 'sent')]);
      await store.upsertMessages(me, 'c1', [msg('m1', status: 'seen'), msg('m1', status: 'seen')]);
      final thread = await store.loadThread(me, 'c1');
      expect(thread, hasLength(1));
      expect(thread.single.status, 'seen');
    });

    test('a sync never overwrites the thumbnail this phone made', () async {
      await store.upsertMessages(me, 'c1', [
        Message(
          id: 'img', conversationId: 'c1', senderId: 'p1', text: 'Image', type: 'image',
          attachmentUrl: 'chat-attachments/c1/img.jpg', timestamp: DateTime.utc(2026), isMe: false,
        ),
      ]);
      expect(await store.imagesWithoutThumbs(me, ['c1']), hasLength(1));
      await store.setThumbPath(me, 'img', '/thumbs/img.png');
      await store.upsertMessages(me, 'c1', [
        Message(
          id: 'img', conversationId: 'c1', senderId: 'p1', text: 'Image', type: 'image',
          attachmentUrl: 'chat-attachments/c1/img.jpg', timestamp: DateTime.utc(2026), isMe: false,
          status: 'seen',
        ),
      ]);
      expect(await store.imagesWithoutThumbs(me, ['c1']), isEmpty);
    });

    test('newest window, chronological, and paging backwards with before', () async {
      await store.upsertMessages(me, 'c1', [
        for (var i = 0; i < 10; i++) msg('m$i', at: DateTime.utc(2026, 10, 1, 9, i)),
      ]);
      final newest = await store.loadThread(me, 'c1', limit: 3);
      expect(newest.map((m) => m.id), ['m7', 'm8', 'm9']);
      final older = await store.loadThread(me, 'c1', limit: 3, before: newest.first.timestamp);
      expect(older.map((m) => m.id), ['m4', 'm5', 'm6']);
    });

    test('a thread is per conversation', () async {
      await store.upsertMessages(me, 'c1', [msg('a', chat: 'c1')]);
      await store.upsertMessages(me, 'c2', [msg('b', chat: 'c2')]);
      expect((await store.loadThread(me, 'c1')).map((m) => m.id), ['a']);
    });
  });

  group('outbox — same database as the thread', () {
    test('order is kept, and a restart reads it back', () async {
      final q = [
        msg('pending_11111111-1111-4111-8111-111111111111', sender: me, text: 'one', status: 'queued'),
        msg('pending_22222222-2222-4222-8222-222222222222', sender: me, text: 'two', status: 'queued'),
      ];
      await CacheService.saveOutbox(me, 'c1', q);
      await restartChatStore();
      expect((await CacheService.loadOutbox('c1', me)).map((m) => m.text), ['one', 'two']);
      expect(await CacheService.outboxChatIds(me), ['c1']);
    });

    test("DE-DUPLICATION BY CLIENT ID: the server row retires its queued copy", () async {
      const uuid = '33333333-3333-4333-8333-333333333333';
      await CacheService.saveOutbox(me, 'c1', [
        msg('pending_$uuid', sender: me, text: 'on my way', status: 'queued'),
      ]);
      // However it got delivered — this screen, the outbox drain, or a sync
      // after the app was killed mid-send — the server row has the same id.
      await store.upsertMessages(me, 'c1', [msg(uuid, sender: me, text: 'on my way')]);
      expect(await CacheService.loadOutbox('c1', me), isEmpty);
      expect((await store.loadThread(me, 'c1')).map((m) => m.id), [uuid]);
    });

    test('a request open when the process died is queued, not sending', () async {
      await CacheService.saveOutbox(me, 'c1', [
        msg('pending_44444444-4444-4444-8444-444444444444', sender: me, status: 'sending'),
      ]);
      expect((await CacheService.loadOutbox('c1', me)).single.status, 'queued');
    });
  });

  group('migration from the SharedPreferences cache of builds ≤1.0.2', () {
    test('imported once, poison removed, old keys deleted', () async {
      final conversations = [
        Conversation(
          id: 'c1', participantId: 'p1', userName: '?', lastMessage: 'Dud',
          lastMessageTime: DateTime.utc(2026, 10, 5), postTitle: 'Shambala boy',
        ).toCacheMap(),
        Conversation(
          id: 'c2', participantId: 'p2', userName: 'Pauline Oyombe', lastMessage: 'Mambo',
          lastMessageTime: DateTime.utc(2026, 9, 6), unreadCount: 1,
        ).toCacheMap(),
      ];
      SharedPreferences.setMockInitialValues({
        SessionScope.scopedKey(SessionKeys.conversations, me): jsonEncode(conversations),
        SessionScope.scopedKey(SessionKeys.messages, me, 'c2'):
            jsonEncode([msg('m1', chat: 'c2', text: 'Mambo').toCacheMap()]),
        SessionScope.scopedKey(SessionKeys.outbox, me, 'c2'):
            jsonEncode([msg('pending_55555555-5555-4555-8555-555555555555', chat: 'c2', sender: me, status: 'queued').toCacheMap()]),
      });

      final list = await store.loadConversations(me);
      expect(list.map((c) => c.id), ['c1', 'c2']);
      expect(list.first.userName, isEmpty, reason: '"?" is imported as unknown');
      expect(list.first.postTitle, 'Shambala boy');
      expect(list.last.userName, 'Pauline Oyombe');
      expect(list.last.unreadCount, 1);
      expect((await store.loadThread(me, 'c2')).single.text, 'Mambo');
      expect(await store.loadOutbox(me, 'c2'), hasLength(1));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty, reason: 'imported keys are deleted');

      // Once: a second open imports nothing again.
      await restartChatStore();
      expect(await store.loadConversations(me), hasLength(2));
    });

    test('another account\'s legacy keys are not imported', () async {
      SharedPreferences.setMockInitialValues({
        SessionScope.scopedKey(SessionKeys.conversations, 'uid-other'): jsonEncode([
          Conversation(id: 'x', userName: 'X', lastMessage: 'x', lastMessageTime: DateTime.utc(2026)).toCacheMap(),
        ]),
      });
      expect(await store.loadConversations(me), isEmpty);
    });
  });

  group('cold start — the database answers with no network at all', () {
    test('list, people and threads come back after a restart', () async {
      await store.applyConversationSync(me, rows: [
        row('c1', participant: 'p1', last: 'Dud', unread: 1, postTitle: 'Shambala boy', postId: 'p'),
      ], people: {'p1': const ChatPerson(id: 'p1', name: 'Alphonse Lincoln', avatarUrl: 'https://x/a.jpg')});
      await store.setAvatarFile(me, 'p1', path: '/media/avatars/p1_abc.png', version: 'abc');
      await store.upsertMessages(me, 'c1', [msg('m1', text: 'Dud')]);

      await restartChatStore();

      final c = (await store.loadConversations(me)).single;
      expect(c.userName, 'Alphonse Lincoln');
      expect(c.userAvatarPath, '/media/avatars/p1_abc.png');
      expect(c.lastMessage, 'Dud');
      expect(c.unreadCount, 1);
      expect(c.postTitle, 'Shambala boy');
      expect((await CacheService.loadMessages('c1', me)).single.text, 'Dud');
    });

    test('a large account opens its list well under a second', () async {
      final rows = [
        for (var i = 0; i < 600; i++)
          row('c$i', participant: 'p$i', at: DateTime.utc(2026, 1, 1).add(Duration(minutes: i))),
      ];
      final people = {for (var i = 0; i < 600; i++) 'p$i': ChatPerson(id: 'p$i', name: 'Person $i')};
      await store.applyConversationSync(me, rows: rows, people: people);
      for (var c = 0; c < 60; c++) {
        await store.upsertMessages(me, 'c$c', [
          for (var i = 0; i < 80; i++)
            msg('c$c-m$i', chat: 'c$c', text: 'message $i in chat $c', at: DateTime.utc(2026, 2, 1, 0, i)),
        ]);
      }
      await restartChatStore();

      final watch = Stopwatch()..start();
      final list = await store.loadConversations(me);
      watch.stop();
      expect(list, hasLength(600));
      expect(list.first.id, 'c599');
      expect(list.every((c) => c.userName.startsWith('Person ')), isTrue);
      expect(watch.elapsedMilliseconds, lessThan(1000), reason: 'list read took ${watch.elapsedMilliseconds}ms');

      final counts = await store.counts(me);
      expect(counts['messages'], 4800);
      final size = File('${dir.path}/${ChatStore.fileNameFor(me)}').lengthSync();
      // Printed for the report: the on-disk cost of a heavy account.
      // ignore: avoid_print
      print('[CHAT_DB] 600 conversations + 4800 messages: ${(size / 1024).round()} KB on disk, '
          'list read in ${watch.elapsedMilliseconds} ms');
    });
  });

  group('sign-out deletes chat data — and nothing else does', () {
    test('only the signed-out account, files and media', () async {
      SessionScope.instance.register(store);
      await store.applyConversationSync(me, rows: [row('c1')], people: const {});
      await store.applyConversationSync('uid-b', rows: [row('b1')], people: const {});
      final media = await ChatStore.mediaDirFor(me, 'avatars');
      File('${media.path}/p1_x.png').writeAsBytesSync([1, 2, 3]);

      await SessionScope.instance.endSession(me);

      expect(File('${dir.path}/${ChatStore.fileNameFor(me)}').existsSync(), isFalse);
      expect(media.existsSync(), isFalse);
      expect(await store.loadConversations('uid-b'), hasLength(1));
    });

    test('a write still in flight after sign-out cannot re-create the file', () async {
      await store.applyConversationSync(me, rows: [row('c1')], people: const {});
      await store.purgeOwner(me);
      await store.upsertMessages(me, 'c1', [msg('late')]);
      await CacheService.saveOutbox(me, 'c1', [msg('pending_late', sender: me)]);
      expect(File('${dir.path}/${ChatStore.fileNameFor(me)}').existsSync(), isFalse);
      // A new session for the account opens it again, empty.
      expect(await store.open(me), isTrue);
      expect(await store.loadConversations(me), isEmpty);
    });

    test('startup removes other accounts\' files, keeps the signed-in one', () async {
      await store.applyConversationSync(me, rows: [row('c1')], people: const {});
      await store.applyConversationSync('uid-old', rows: [row('o1')], people: const {});
      await store.closeAllForTest();
      await store.purgeForeign(me);
      expect(File('${dir.path}/${ChatStore.fileNameFor('uid-old')}').existsSync(), isFalse);
      expect(await store.loadConversations(me), hasLength(1));
    });

    test('an expired token or a 401 is not a sign-out: nothing here listens for one', () {
      // The only deletion paths are purgeOwner (SessionScope.endSession, i.e.
      // Firebase reporting no user) and purgeForeign (a different account at
      // startup). Pinned at the source so a "clear cache on auth error" can
      // not creep in.
      final src = File('lib/services/chat_store.dart').readAsStringSync();
      expect(RegExp(r'statusCode|PostgrestException|AuthException|authStateChanges').hasMatch(src),
          isFalse);
      for (final path in const [
        'lib/http_client_with_token.dart',
        'lib/services/supabase_auth_bridge.dart',
        'lib/services/chat_sync.dart',
      ]) {
        final other = File(path).readAsStringSync();
        expect(RegExp(r'purgeOwner|deleteEverything|clearThread').hasMatch(other), isFalse,
            reason: '$path must not delete chat data');
      }
    });
  });
}
