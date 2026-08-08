import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/services/chat_service_supabase.dart';

/// THE POST-NAME INVARIANT
///
/// > If a conversation is associated with a post, every place that renders that
/// > conversation must display the post's name — regardless of where the chat
/// > was opened or created.
///
/// And its other half, which matters just as much:
///
/// > A conversation with `post_id IS NULL` is genuinely general. Nothing may
/// > invent a name for it.
///
/// Production data was never the problem: all 19 post-scoped chats pointed at a
/// live post with a title. The name was dropped at NAVIGATION time — an entry
/// point that never captured the post, and a read that never joined it — so the
/// guards here are aimed at exactly those two places.
void main() {
  group('postTitleOf / postIdOf — reading the embedded join', () {
    test('a post-scoped row yields its title', () {
      expect(
        ChatServiceSupabase.postTitleOf({
          'post_id': '18657246-9a2c-4c11-8ead-2f4e977694ed',
          'posts': {'title': 'Emergency Dog Trainer'},
        }),
        'Emergency Dog Trainer',
      );
    });

    test('a general conversation yields null, never an invented name', () {
      // The real production row: chats 9dc93193…, post_id NULL, active today.
      const generalRow = {'post_id': null, 'posts': null};
      expect(ChatServiceSupabase.postTitleOf(generalRow), isNull);
      expect(ChatServiceSupabase.postIdOf(generalRow), isNull);
    });

    test('a missing join is null, not a crash', () {
      expect(ChatServiceSupabase.postTitleOf({'post_id': 'x'}), isNull);
      expect(ChatServiceSupabase.postTitleOf(null), isNull);
    });

    test('a blank or whitespace title is null, not an empty pin', () {
      // The renderers gate on `isNotEmpty`; normalising here means a row with a
      // whitespace title can never produce a 📌 with nothing beside it.
      expect(
        ChatServiceSupabase.postTitleOf({
          'posts': {'title': '   '}
        }),
        isNull,
      );
    });

    test('titles keep their real text, trimmed', () {
      // Production holds 'Airtel Wifi Installation ' with a trailing space.
      expect(
        ChatServiceSupabase.postTitleOf({
          'posts': {'title': 'Airtel Wifi Installation '}
        }),
        'Airtel Wifi Installation',
      );
    });

    test('a non-string title is refused rather than stringified', () {
      expect(
        ChatServiceSupabase.postTitleOf({
          'posts': {'title': 42}
        }),
        isNull,
      );
    });

    test('an empty post_id reads as no post', () {
      expect(ChatServiceSupabase.postIdOf({'post_id': ''}), isNull);
      expect(ChatServiceSupabase.postIdOf({'post_id': '  '}), isNull);
    });
  });

  group('Conversation carries post context through the cache', () {
    test('a post-scoped conversation round-trips its title', () {
      final conv = Conversation(
        id: 'c1',
        userName: 'Alphonse Lincoln',
        lastMessage: 'Hi about the Interior Design job',
        lastMessageTime: DateTime.utc(2026, 8, 8),
        postId: '9e0062b0-b38c-4e85-9201-a398a2171f7f',
        postTitle: 'Nahitaji fundi wa Interior Design',
      );
      final restored = Conversation.fromCacheMap(conv.toCacheMap());
      expect(restored.postId, conv.postId);
      expect(restored.postTitle, 'Nahitaji fundi wa Interior Design');
    });

    test('a general conversation round-trips as general', () {
      final conv = Conversation(
        id: 'c2',
        userName: 'Alphonse Lincoln',
        lastMessage: 'How much do you charge for this job',
        lastMessageTime: DateTime.utc(2026, 8, 8),
      );
      final restored = Conversation.fromCacheMap(conv.toCacheMap());
      expect(restored.postId, isNull);
      expect(restored.postTitle, isNull,
          reason: 'a general chat must not acquire a post name from the cache');
    });
  });

  group('every read of a chat row joins the post (source guards)', () {
    String read(String path) => File(path).readAsStringSync();

    test('there is ONE post-context select and everything uses it', () {
      // Four hand-written selects existed; two joined `posts` and two did not,
      // and the notifications list happened to pick one that did not.
      for (final path in const [
        'lib/services/chat_service_supabase.dart',
        'lib/screens/notifications_screen.dart',
        'lib/main.dart',
      ]) {
        final src = read(path);
        final handWritten = RegExp(r"posts!chats_post_id_fkey\(title\)")
            .allMatches(src)
            .length;
        final expected =
            path.endsWith('chat_service_supabase.dart') ? 1 : 0;
        expect(handWritten, expected,
            reason: '$path should use ChatServiceSupabase.chatRowSelect');
      }
    });

    test('the notifications list reads the post it is about', () {
      // This path supplies a chat id, so resolution short-circuits to `existing`
      // and NO lookup ever runs — whatever is missing here stays missing for the
      // life of the screen. That is why the banner, "View post" and "Job status"
      // were all absent for a chat opened from the bell.
      final src = read('lib/screens/notifications_screen.dart');
      final start = src.indexOf('Future<void> _openChatById(');
      expect(start, greaterThan(-1));
      final body = src.substring(start, src.indexOf('void _openMessages()', start));
      expect(body.contains('ChatServiceSupabase.chatRowSelect'), isTrue);
      expect(body.contains('postId: postId'), isTrue);
      expect(body.contains('postTitle: postTitle'), isTrue);
    });

    test('the resolve path can recover a title without the caller', () {
      // _findExistingChat used to `.select()` bare while findMostRecentChatForPair
      // joined — so only one of the two lookups could name its post.
      final src = read('lib/services/chat_service_supabase.dart');
      final start = src.indexOf('static Future<Map<String, dynamic>?> _findExistingChat');
      final body = src.substring(start, src.indexOf('_insertChatRow', start));
      expect(body.contains('.select(chatRowSelect)'), isTrue);
      expect(body.contains('.select()'), isFalse);
    });

    test('a chat created on first send names its post immediately', () {
      // Otherwise AppProvider.updateConversation inserts it into the Messages
      // list with an id and no name, and the 📌 only appears on the next poll.
      final src = read('lib/services/chat_service_supabase.dart');
      final start = src.indexOf('static Future<Conversation> createChat');
      final body = src.substring(
        start,
        src.indexOf(
            'static Future<({Map<String, dynamic>? row, bool ok})> findExistingChat',
            start),
      );
      expect(body.contains('String? postTitle'), isTrue);
      expect(body.contains('postTitle: postTitle ?? postTitleOf(row)'), isTrue);
    });

    test('ChatScreen passes the known title into creation', () {
      final src = read('lib/screens/messages_screen.dart');
      final start = src.indexOf('Future<bool> _ensureChatCreated()');
      final body = src.substring(start, src.indexOf('Future<void> _sendMessage()', start));
      expect(body.contains('postTitle: widget.conversation.postTitle'), isTrue);
    });

    test('the applicant card carries its listing into the profile', () {
      final src = read('lib/widgets/applicant_card.dart');
      expect(src.contains('contextPostId: application.postId'), isTrue);
      expect(src.contains('contextPostTitle: postTitle'), isTrue);
    });

    test('both applicant surfaces supply the post title', () {
      expect(read('lib/screens/applications_screen.dart')
          .contains('postTitle: widget.postTitle'), isTrue);
      expect(read('lib/screens/post_detail_screen.dart')
          .contains('postTitle: widget.post.title'), isTrue);
    });

    test('every renderer gates the pin on a real title', () {
      // No 📌 with nothing next to it, and nothing invented for a general chat.
      final list = read('lib/screens/messages_screen.dart');
      expect(
        list.contains(
            "conversation.postTitle != null && conversation.postTitle!.isNotEmpty"),
        isTrue,
      );
      expect(
        list.contains("_postTitle != null && _postTitle!.isNotEmpty"),
        isTrue,
      );
    });
  });
}
