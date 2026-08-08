import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/chat_resolution.dart';

/// §D1/§D2 — "if a conversation exists between these participants for the same
/// logical context, every Help24 entry point must open that exact conversation."
///
/// The decision function and the identity rule are pure and tested directly.
/// The wiring (which entry point passes what) is pinned by source guards,
/// because that is exactly where the two defects lived — not in the lookup,
/// which was always correct.
void main() {
  group('chatResolutionFor', () {
    test('caller already knows the id → existing, no lookup needed', () {
      // Messages tab, FCM tap, notifications list.
      expect(
        chatResolutionFor(
          knownId: true,
          lookupDone: false,
          lookupSucceeded: false,
          found: false,
        ),
        ChatResolution.existing,
      );
    });

    test('lookup in flight → resolving, never absent', () {
      expect(
        chatResolutionFor(
          knownId: false,
          lookupDone: false,
          lookupSucceeded: false,
          found: false,
        ),
        ChatResolution.resolving,
      );
    });

    test('THE BUG: lookup found a conversation → existing, not absent', () {
      expect(
        chatResolutionFor(
          knownId: false,
          lookupDone: true,
          lookupSucceeded: true,
          found: true,
        ),
        ChatResolution.existing,
      );
    });

    test('lookup completed and found nothing → absent', () {
      expect(
        chatResolutionFor(
          knownId: false,
          lookupDone: true,
          lookupSucceeded: true,
          found: false,
        ),
        ChatResolution.absent,
      );
    });

    test('OFFLINE: lookup failed → unresolved, NEVER absent', () {
      // The whole point. Offline must not read as "no conversation exists",
      // because that offers to start a second one beside the real thread.
      expect(
        chatResolutionFor(
          knownId: false,
          lookupDone: true,
          lookupSucceeded: false,
          found: false,
        ),
        ChatResolution.unresolved,
      );
    });
  });

  group('showsStartConversation — the gate that was missing', () {
    test('only a completed lookup that found nothing may offer it', () {
      expect(showsStartConversation(ChatResolution.absent), isTrue);
    });

    test('resolving, existing and unresolved must never offer it', () {
      for (final r in [
        ChatResolution.resolving,
        ChatResolution.existing,
        ChatResolution.unresolved,
      ]) {
        expect(showsStartConversation(r), isFalse, reason: '$r offered it');
      }
    });

    test('progress is shown only while resolving', () {
      expect(showsResolvingProgress(ChatResolution.resolving), isTrue);
      for (final r in [
        ChatResolution.existing,
        ChatResolution.absent,
        ChatResolution.unresolved,
      ]) {
        expect(showsResolvingProgress(r), isFalse);
      }
    });

    test('no state both shows progress and offers to start', () {
      for (final r in ChatResolution.values) {
        expect(showsResolvingProgress(r) && showsStartConversation(r), isFalse);
      }
    });
  });

  group('canonicalPair — participant order must not create a second chat', () {
    const a = 'k4DZSMyRNRNMRpXM0SypV5v6IHo2';
    const b = 'nlAJnbHFktNTYEGPPPrBE1zu0RB2';

    test('reversed participant order yields the SAME key', () {
      expect(canonicalPair(a, b), canonicalPair(b, a));
    });

    test('ordering satisfies the DB check constraint user1 < user2', () {
      for (final pair in [canonicalPair(a, b)!, canonicalPair(b, a)!]) {
        expect(pair.user1.compareTo(pair.user2) < 0, isTrue);
      }
    });

    test('whitespace does not fork the identity', () {
      expect(canonicalPair('  $a  ', b), canonicalPair(a, b));
    });

    test('a conversation needs two distinct people', () {
      expect(canonicalPair(a, a), isNull);
      expect(canonicalPair('', b), isNull);
      expect(canonicalPair(a, '   '), isNull);
    });
  });

  group('entry-point wiring (source guards)', () {
    String read(String path) => File(path).readAsStringSync();

    test('the read-only lookup creates nothing', () {
      final src = read('lib/services/chat_service_supabase.dart');
      final start = src.indexOf('static Future<({Map<String, dynamic>? row, bool ok})> findExistingChat');
      final end = src.indexOf('findMostRecentChatForPair');
      expect(start, greaterThan(-1));
      final body = src.substring(start, end);
      expect(body.contains('.insert('), isFalse, reason: 'findExistingChat must not write');
      expect(body.contains('_insertChatRow'), isFalse);
    });

    test('the most-recent lookup creates nothing and ignores empty chats', () {
      final src = read('lib/services/chat_service_supabase.dart');
      final start = src.indexOf('static Future<({Map<String, dynamic>? row, bool ok})> findMostRecentChatForPair');
      final body = src.substring(start, start + 1400);
      expect(body.contains('.insert('), isFalse);
      // Rows abandoned by a failed first send must not be adopted as "the
      // conversation" — same filter the Messages tab lists by.
      expect(body.contains("neq('last_message', '')"), isTrue);
      expect(body.contains("order('updated_at', ascending: false)"), isTrue);
    });

    test('Provider Profile resolves the most recent thread (§D2)', () {
      final src = read('lib/screens/provider_profile_screen.dart');
      expect(src.contains('resolveMostRecent: true'), isTrue);
    });

    test('contextual entry points keep their own post scope', () {
      // Application, post detail, saved: they must NOT opt into most-recent,
      // or a post-scoped chat would silently retarget another post's thread.
      for (final path in const [
        'lib/screens/applications_screen.dart',
        'lib/widgets/post_flows.dart',
      ]) {
        expect(
          read(path).contains('resolveMostRecent'),
          isFalse,
          reason: '$path must keep post-scoped resolution',
        );
      }
    });

    test('ChatScreen gates the start-conversation copy behind the resolution', () {
      final src = read('lib/screens/messages_screen.dart');
      final idx = src.indexOf("'Start the conversation'");
      expect(idx, greaterThan(-1));
      // The nearest preceding guard must be the gate, not a bare isEmpty check.
      final preceding = src.substring(0, idx);
      final gate = preceding.lastIndexOf('showsStartConversation(_resolution)');
      final bareEmpty = preceding.lastIndexOf('if (combined.isEmpty) {');
      expect(gate, greaterThan(bareEmpty),
          reason: 'Start-conversation copy is not behind showsStartConversation');
    });

    test('the lookup key uses the entry point post, not the adopted one', () {
      final src = read('lib/screens/messages_screen.dart');
      final start = src.indexOf('Future<void> _resolveExistingChat()');
      final body = src.substring(start, src.indexOf('_beginExistingChat();', start));
      expect(body.contains('postId: widget.conversation.postId'), isTrue,
          reason: 'resolution must key on the entry point post');
    });
  });
}
