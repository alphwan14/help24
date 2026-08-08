import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:help24/models/post_model.dart';
import 'package:help24/services/cache_service.dart';
import 'package:help24/services/session_scope.dart';

/// Stage 3 — the message cache must make an already-known conversation open
/// without a network round trip, WITHOUT weakening the account isolation that
/// SessionScope exists to guarantee.
///
/// Measured baseline on a Galaxy S20+ (release build, production data):
///   warm disk cache → cached paint at +25 ms, server page at +436 ms
///   cold cache      → NO cached paint, server page at +522 ms
/// The memo removes the 25 ms; the prefetch removes the 522 ms case.
Message _msg(String id, String chatId, String senderId, String text) => Message(
      id: id,
      conversationId: chatId,
      senderId: senderId,
      text: text,
      timestamp: DateTime.utc(2026, 8, 8, 12, 0),
      isMe: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CacheService.resetMessageMemo();
  });

  group('peekMessages — synchronous first paint', () {
    const uid = 'uid-A';
    const chat = 'chat-1';

    test('null before anything is cached — "unknown", not "empty"', () {
      // The distinction the whole offline contract rests on.
      expect(CacheService.peekMessages(chat, uid), isNull);
    });

    test('a save makes the thread available synchronously', () async {
      await CacheService.saveMessages(uid, chat, [_msg('m1', chat, 'other', 'hi')]);
      final peeked = CacheService.peekMessages(chat, uid);
      expect(peeked, isNotNull);
      expect(peeked!.single.text, 'hi');
    });

    test('a disk load memoises, so the SECOND open needs no await', () async {
      await CacheService.saveMessages(uid, chat, [_msg('m1', chat, 'other', 'hi')]);
      CacheService.resetMessageMemo(); // simulate a fresh process
      expect(CacheService.peekMessages(chat, uid), isNull);

      await CacheService.loadMessages(chat, uid); // the async path runs once
      expect(CacheService.peekMessages(chat, uid), isNotNull);
    });

    test('empty ids never address anything', () {
      expect(CacheService.peekMessages('', uid), isNull);
      expect(CacheService.peekMessages(chat, ''), isNull);
    });
  });

  group('account isolation — the memo must not become a leak', () {
    const chat = 'shared-chat-id';

    test('B cannot peek A\'s thread, even for the same chat id', () async {
      await CacheService.saveMessages('uid-A', chat, [
        _msg('m1', chat, 'uid-A', 'private to A'),
      ]);

      // Same chat id, different reader. The key is namespaced by uid, so this
      // is not a filter that could be forgotten — it cannot be addressed.
      expect(CacheService.peekMessages(chat, 'uid-B'), isNull);
      expect(await CacheService.loadMessages(chat, 'uid-B'), isEmpty);
    });

    test('sign-out drops the mirror', () async {
      await CacheService.saveMessages('uid-A', chat, [
        _msg('m1', chat, 'uid-A', 'private to A'),
      ]);
      expect(CacheService.peekMessages(chat, 'uid-A'), isNotNull);

      const MessageMemoScope().resetForSignOut();

      expect(CacheService.peekMessages(chat, 'uid-A'), isNull);
    });

    test('MessageMemoScope is a SessionScoped member', () {
      // If it stops being one it silently stops being reset, and the second
      // defence SessionScope insists on quietly disappears.
      expect(const MessageMemoScope(), isA<SessionScoped>());
    });

    test('the memo key is the SAME scoped key the disk uses', () async {
      // A divergent key would let memory and disk disagree about ownership.
      await CacheService.saveMessages('uid-A', chat, [
        _msg('m1', chat, 'uid-A', 'x'),
      ]);
      final prefs = await SharedPreferences.getInstance();
      final expected =
          SessionScope.scopedKey(SessionKeys.messages, 'uid-A', chat);
      expect(prefs.getKeys(), contains(expected));
      expect(SessionScope.uidScopedPrefixes, contains(SessionKeys.messages));
    });
  });

  group('prefetch budget is per SESSION, not per emission', () {
    // The conversation stream emits on every poll and every realtime nudge.
    // A per-call counter therefore warms the NEXT five each time and slowly
    // downloads every thread the account has. Caught on device: a conversation
    // at list position 7 was already warm with a 5-thread limit.
    //
    // Modelled here as the pure loop condition, because the real method needs a
    // live Supabase client.
    Set<String> simulate({
      required List<String> conversationIds,
      required int emissions,
      required int limit,
      required bool sessionScopedBudget,
    }) {
      final attempted = <String>{};
      for (var e = 0; e < emissions; e++) {
        var warmedThisCall = 0;
        for (final id in conversationIds) {
          final exhausted = sessionScopedBudget
              ? attempted.length >= limit
              : warmedThisCall >= limit;
          if (exhausted) break;
          if (!attempted.add(id)) continue;
          warmedThisCall++;
        }
      }
      return attempted;
    }

    final ids = List.generate(40, (i) => 'chat-$i');

    test('THE BUG: a per-call counter drains the whole list', () {
      final attempted = simulate(
        conversationIds: ids,
        emissions: 8,
        limit: 5,
        sessionScopedBudget: false,
      );
      expect(attempted.length, greaterThan(5));
      expect(attempted.length, 40, reason: 'it eventually fetches everything');
    });

    test('a session budget stops at the limit no matter how many emissions', () {
      final attempted = simulate(
        conversationIds: ids,
        emissions: 8,
        limit: 5,
        sessionScopedBudget: true,
      );
      expect(attempted.length, 5);
      // And it is the MOST RECENT five, which is what the user is about to tap.
      expect(attempted, ids.take(5).toSet());
    });

    test('a single emission is identical under both rules', () {
      expect(
        simulate(conversationIds: ids, emissions: 1, limit: 5, sessionScopedBudget: true),
        simulate(conversationIds: ids, emissions: 1, limit: 5, sessionScopedBudget: false),
      );
    });
  });

  group('round trip', () {
    test('messages survive a process restart via disk', () async {
      const uid = 'uid-A';
      const chat = 'chat-1';
      await CacheService.saveMessages(uid, chat, [
        _msg('m1', chat, 'other', 'first'),
        _msg('m2', chat, uid, 'second'),
      ]);

      CacheService.resetMessageMemo(); // new process, memory gone, disk intact
      final restored = await CacheService.loadMessages(chat, uid);

      expect(restored.map((m) => m.text), ['first', 'second']);
    });

    test('saving an empty list does not resurrect a stale thread', () async {
      const uid = 'uid-A';
      const chat = 'chat-1';
      await CacheService.saveMessages(uid, chat, [_msg('m1', chat, 'o', 'hi')]);
      await CacheService.saveMessages(uid, chat, const []);

      expect(CacheService.peekMessages(chat, uid), isEmpty);
      expect(await CacheService.loadMessages(chat, uid), isEmpty);
    });
  });
}
