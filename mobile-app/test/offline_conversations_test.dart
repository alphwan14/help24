import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/services/chat_service_supabase.dart';

/// Regression suite: NO INTERNET MUST NEVER MEAN "NO CONVERSATIONS".
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// `watchConversations` answered a failed fetch with `controller.add([])`. A
/// dead network was therefore published to every listener as the FACT "this
/// account has no conversations", and the two things downstream both believed
/// it:
///
///   * `AppProvider` replaced `_conversations` with the empty list;
///   * and wrote that empty list to disk via `CacheService.saveConversations`,
///     which is deliberately unconditional so one account's cached chats can
///     never outlive it and surface under the next.
///
/// The conversation poll runs every 15s (60s once Realtime is confirmed) and is
/// never paused while offline, so a user who walked into a lift lost the
/// Messages tab AND its on-disk history within one tick — and got it back only
/// after a successful fetch. That is the "sometimes 'No Internet' even though
/// conversations already exist locally" report, and it was data loss, not just
/// a rendering problem.
///
/// The rule below is the fix, stated where it can be checked without a network.
void main() {
  group('conversationEmissionFor — an error is not an emptiness', () {
    test('a successful fetch always publishes its list', () {
      expect(
        conversationEmissionFor(fetchSucceeded: true, hasDeliveredList: false),
        ConversationEmission.list,
      );
      expect(
        conversationEmissionFor(fetchSucceeded: true, hasDeliveredList: true),
        ConversationEmission.list,
      );
    });

    test('a failure AFTER a good list publishes nothing at all', () {
      // The load-bearing case. Silence keeps the conversations on screen and,
      // just as importantly, keeps the disk cache intact — nothing reaches the
      // listener, so nothing overwrites it.
      expect(
        conversationEmissionFor(fetchSucceeded: false, hasDeliveredList: true),
        ConversationEmission.silence,
      );
    });

    test('a failure BEFORE any list publishes an error, never an empty list', () {
      // There is no history to protect here, but the listener still needs its
      // skeleton to stop. An error says "this failed"; `[]` would have said
      // "this is empty", which is a different claim and the one that misled the
      // UI into "No messages yet".
      expect(
        conversationEmissionFor(fetchSucceeded: false, hasDeliveredList: false),
        ConversationEmission.error,
      );
    });

    test('an emptiness is only ever published by a fetch that succeeded', () {
      // Restated as the invariant the cache write depends on: every list that
      // reaches AppProvider — including an empty one — is an answer from the
      // server, so persisting it records a fact instead of an outage.
      for (final delivered in [true, false]) {
        expect(
          conversationEmissionFor(
              fetchSucceeded: false, hasDeliveredList: delivered),
          isNot(ConversationEmission.list),
        );
      }
    });

    test('repeated failures never escalate into an empty list', () {
      // The poll fires every 15-60s while offline. Ten ticks in a lift must be
      // ten silences, not one wiped account.
      for (var tick = 0; tick < 10; tick++) {
        expect(
          conversationEmissionFor(fetchSucceeded: false, hasDeliveredList: true),
          ConversationEmission.silence,
        );
      }
    });
  });

  group('cached conversations survive the disk round-trip', () {
    test('everything a tile renders comes back', () {
      final conversation = Conversation(
        id: 'chat-1',
        participantId: 'user-2',
        userName: 'Grace Wanjiru',
        userAvatar: 'https://cdn.help24.co.ke/a/grace.jpg',
        lastMessage: 'On my way',
        lastMessageTime: DateTime.utc(2026, 7, 27, 9, 15),
        unreadCount: 3,
        postId: 'post-1',
        postTitle: 'Fix a leaking kitchen tap',
      );

      final restored = Conversation.fromCacheMap(conversation.toCacheMap());

      expect(restored.id, 'chat-1');
      expect(restored.participantId, 'user-2');
      expect(restored.userName, 'Grace Wanjiru');
      expect(restored.userAvatar, isNotEmpty);
      expect(restored.lastMessage, 'On my way');
      expect(restored.unreadCount, 3);
      expect(restored.postTitle, 'Fix a leaking kitchen tap');
      expect(
        restored.lastMessageTime.toUtc(),
        conversation.lastMessageTime.toUtc(),
      );
    });

    test('a whole list round-trips, so a relaunch on a plane is readable', () {
      final list = [
        for (var i = 0; i < 5; i++)
          Conversation(
            id: 'chat-$i',
            participantId: 'user-$i',
            userName: 'Contact $i',
            userAvatar: '',
            lastMessage: 'Message $i',
            lastMessageTime: DateTime.utc(2026, 7, 27, 9, i),
          ),
      ];

      final restored = list
          .map((c) => Conversation.fromCacheMap(c.toCacheMap()))
          .toList();

      expect(restored, hasLength(5));
      expect(restored.map((c) => c.id), list.map((c) => c.id));
      expect(restored.map((c) => c.lastMessage), list.map((c) => c.lastMessage));
    });
  });
}
