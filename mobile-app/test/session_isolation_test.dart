import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/services/cache_service.dart';
import 'package:help24/services/session_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression suite for the cross-account data leak.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// Account A signed in, its conversation list was written to a device-global
/// SharedPreferences key, and account C — signing in later on the same device
/// with no conversations of its own — hydrated from that key and rendered A's
/// chat list as its own. Two defects combined: an unscoped cache key, and a
/// merge in AppProvider that re-installed the longer previous list whenever the
/// incoming one was shorter.
///
/// These tests assert the two properties that make that impossible:
///   1. a cache written as A is UNREADABLE as C (structural isolation), and
///   2. ending a session DESTROYS the data it owned (no residue).
void main() {
  const uidA = 'firebase-uid-account-a';
  const uidB = 'firebase-uid-account-b';
  const uidC = 'firebase-uid-account-c';

  Conversation conv(String id, String lastMessage) => Conversation(
        id: id,
        participantId: 'other-$id',
        userName: 'Someone',
        userAvatar: '',
        lastMessage: lastMessage,
        lastMessageTime: DateTime.utc(2026, 7, 24, 10),
      );

  Message msg(String id, String text, String senderId) => Message(
        id: id,
        senderId: senderId,
        text: text,
        timestamp: DateTime.utc(2026, 7, 24, 10),
        isMe: false,
      );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Conversation cache is scoped to the account that wrote it', () {
    test('a list written as A is invisible to B and C', () async {
      await CacheService.saveConversations(uidA, [
        conv('chat-1', 'See you at 3pm'),
        conv('chat-2', 'Payment sent'),
      ]);

      expect((await CacheService.loadConversations(uidA)).length, 2);
      expect(await CacheService.loadConversations(uidB), isEmpty);
      expect(await CacheService.loadConversations(uidC), isEmpty);
    });

    test('an account with no conversations persists that emptiness', () async {
      // The original code skipped the write when the list was empty, so an
      // account with zero chats could never overwrite its predecessor's cache.
      await CacheService.saveConversations(uidA, [conv('chat-1', 'hello')]);
      await CacheService.saveConversations(uidA, []);

      expect(await CacheService.loadConversations(uidA), isEmpty);
    });

    test('two accounts hold independent lists simultaneously', () async {
      await CacheService.saveConversations(uidA, [conv('a1', 'from A')]);
      await CacheService.saveConversations(uidB, [conv('b1', 'from B')]);

      final a = await CacheService.loadConversations(uidA);
      final b = await CacheService.loadConversations(uidB);
      expect(a.single.lastMessage, 'from A');
      expect(b.single.lastMessage, 'from B');
    });

    test('an empty uid can neither read nor write', () async {
      await CacheService.saveConversations('', [conv('x', 'leak')]);
      expect(await CacheService.loadConversations(''), isEmpty);
      expect(await CacheService.loadConversations(uidA), isEmpty);
    });
  });

  group('Message bodies never cross accounts', () {
    test('a thread cached as A is unreadable as C', () async {
      await CacheService.saveMessages(uidA, 'chat-1', [
        msg('m1', 'My M-Pesa number is 07xx', uidA),
      ]);

      expect((await CacheService.loadMessages('chat-1', uidA)).length, 1);
      // Same chat id, different reader: the key does not exist for C.
      expect(await CacheService.loadMessages('chat-1', uidC), isEmpty);
    });

    test('the outbox is scoped too', () async {
      await CacheService.saveOutbox(uidA, 'chat-1', [
        msg('m1', 'queued while offline', uidA),
      ]);

      expect((await CacheService.loadOutbox('chat-1', uidA)).length, 1);
      expect(await CacheService.loadOutbox('chat-1', uidC), isEmpty);
    });
  });

  group('Ending a session destroys what it owned', () {
    test('A\'s caches are gone after sign-out and C starts clean', () async {
      await CacheService.saveConversations(uidA, [conv('chat-1', 'private')]);
      await CacheService.saveMessages(uidA, 'chat-1', [msg('m1', 'private', uidA)]);
      await CacheService.saveOutbox(uidA, 'chat-1', [msg('m2', 'queued', uidA)]);

      await SessionScope.instance.endSession(uidA);

      expect(await CacheService.loadConversations(uidA), isEmpty);
      expect(await CacheService.loadMessages('chat-1', uidA), isEmpty);
      expect(await CacheService.loadOutbox('chat-1', uidA), isEmpty);
      expect(await CacheService.loadConversations(uidC), isEmpty);
    });

    test('signing out of A leaves B\'s cache intact', () async {
      await CacheService.saveConversations(uidA, [conv('a1', 'from A')]);
      await CacheService.saveConversations(uidB, [conv('b1', 'from B')]);

      await SessionScope.instance.endSession(uidA);

      expect(await CacheService.loadConversations(uidA), isEmpty);
      expect((await CacheService.loadConversations(uidB)).single.lastMessage,
          'from B');
    });

    test('device-local chat prefs do not survive a session', () async {
      SharedPreferences.setMockInitialValues({
        'help24_muted_chats': ['chat-1'],
        'help24_chat_cleared_chat-1': '2026-07-24T10:00:00Z',
        'help24_chat_hidden_chat-1': '["m1"]',
        'help24_cn_chat-1': '[]',
      });

      await SessionScope.instance.endSession(uidA);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((k) => k.startsWith('help24_muted')), isEmpty);
      expect(prefs.getKeys().where((k) => k.startsWith('help24_chat_')), isEmpty);
      expect(prefs.getKeys().where((k) => k.startsWith('help24_cn_')), isEmpty);
    });
  });

  group('Startup sweep retires data from the leaking build', () {
    test('the pre-scoping global conversation key is deleted', () async {
      SharedPreferences.setMockInitialValues({
        // Exactly the key that caused the leak, as written by an old build.
        'help24_cache_conversations': '[{"id":"chat-1"}]',
      });

      await SessionScope.instance.purgeForeignScopes(uidC);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('help24_cache_conversations'), isNull);
    });

    test('legacy chat-keyed message caches are deleted', () async {
      SharedPreferences.setMockInitialValues({
        // Old shape: <prefix><chatId>, no uid segment.
        'help24_cache_messages_chat-1': '[]',
        'help24_outbox_chat-1': '[]',
      });

      await SessionScope.instance.purgeForeignScopes(uidC);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((k) => k.contains('chat-1')), isEmpty);
    });

    test('a foreign account\'s data is swept, the current account\'s is kept',
        () async {
      await CacheService.saveConversations(uidA, [conv('a1', 'from A')]);
      await CacheService.saveConversations(uidC, [conv('c1', 'from C')]);

      await SessionScope.instance.purgeForeignScopes(uidC);

      expect(await CacheService.loadConversations(uidA), isEmpty);
      expect((await CacheService.loadConversations(uidC)).single.lastMessage,
          'from C');
    });

    test('with nobody signed in, every user-scoped key is swept', () async {
      await CacheService.saveConversations(uidA, [conv('a1', 'from A')]);
      await CacheService.saveConversations(uidC, [conv('c1', 'from C')]);

      await SessionScope.instance.purgeForeignScopes(null);

      expect(await CacheService.loadConversations(uidA), isEmpty);
      expect(await CacheService.loadConversations(uidC), isEmpty);
    });

    test('a relaunch by the SAME user keeps their chat preferences', () async {
      SharedPreferences.setMockInitialValues({
        'help24_session_owner': uidC,
        'help24_muted_chats': ['chat-1'],
      });

      await SessionScope.instance.purgeForeignScopes(uidC);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('help24_muted_chats'), ['chat-1']);
    });

    test('an account change across a process restart clears them', () async {
      // The previous session never signed out cleanly (app killed), so the
      // un-namespaced chat prefs still belong to A when C signs in.
      SharedPreferences.setMockInitialValues({
        'help24_session_owner': uidA,
        'help24_muted_chats': ['chat-1'],
        'help24_chat_hidden_chat-1': '["m1"]',
      });

      await SessionScope.instance.purgeForeignScopes(uidC);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('help24_muted_chats'), isNull);
      expect(prefs.getString('help24_chat_hidden_chat-1'), isNull);
      expect(prefs.getString('help24_session_owner'), uidC);
    });

    test('public marketplace caches are never swept', () async {
      SharedPreferences.setMockInitialValues({
        'help24_cache_posts': '[]',
        'help24_cache_jobs': '[]',
      });

      await SessionScope.instance.purgeForeignScopes(uidC);
      await SessionScope.instance.endSession(uidC);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('help24_cache_posts'), isNotNull);
      expect(prefs.getString('help24_cache_jobs'), isNotNull);
    });
  });

  group('The A → B → C sequence from the bug report', () {
    test('C inherits nothing from A or B', () async {
      // A signs in and chats.
      await CacheService.saveConversations(uidA, [
        conv('chat-1', 'See you at 3pm'),
        conv('chat-2', 'Payment sent'),
      ]);
      await CacheService.saveMessages(
          uidA, 'chat-1', [msg('m1', 'private', uidA)]);
      await SessionScope.instance.endSession(uidA);

      // B signs in — no conversations of its own — and signs out.
      expect(await CacheService.loadConversations(uidB), isEmpty);
      await CacheService.saveConversations(uidB, []);
      await SessionScope.instance.endSession(uidB);

      // C signs in.
      expect(await CacheService.loadConversations(uidC), isEmpty);
      expect(await CacheService.loadMessages('chat-1', uidC), isEmpty);
      expect(await CacheService.loadOutbox('chat-1', uidC), isEmpty);

      // And nothing of A's is left anywhere on the device.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((k) => k.contains(uidA)), isEmpty);
    });
  });
}
