import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/services/outbox_store.dart';

/// AN UNSENT MESSAGE IS STILL THE LATEST THING IN THE CONVERSATION.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// Reproduced on the physical S20+ against production, in airplane mode:
///
///   1. Send "OFFLINE test message" in a chat whose last delivered message was
///      "Habari yako". It appears in the thread, correctly marked.
///   2. Leave the conversation.
///   3. The Messages tab shows "Habari yako / 5m ago". The message just
///      composed is absent — no preview, no marker, no trace.
///   4. Restore the network. A minute later it is STILL undelivered, and
///      `chat_messages` for that chat holds only "Habari yako".
///
/// Both halves are one defect: the queue was owned by `_ChatScreenState`. The
/// list reads `chats.last_message`, which is written only after a successful
/// insert, so nothing there could know about a queued message; and the resend
/// was a reconnect subscription opened in that screen's `initState`, so leaving
/// the thread left the queue with no listener at all.
///
/// `OutboxStore` is the owner that outlives the screen. These tests pin what it
/// must answer, including the two rules that keep it safe: one message can only
/// ever have one sender, and one account can never read another's queue.
void main() {
  Message queued(String id, String text, DateTime at,
          {String status = OutboxStatus.queued}) =>
      Message(
        id: id,
        senderId: 'me',
        text: text,
        timestamp: at,
        isMe: true,
        status: status,
      );

  final t0 = DateTime.utc(2026, 9, 4, 15, 30);

  setUp(() => OutboxStore.instance.resetForSignOut());
  tearDown(() => OutboxStore.instance.resetForSignOut());

  group('pendingFor — what the Messages tab must show', () {
    test('a queued message is the preview, not the delivered one', () {
      OutboxStore.instance.publish('uid-a', 'chat-1', [
        queued('pending_1', 'OFFLINE test message', t0),
      ]);
      final pending = OutboxStore.instance.pendingFor('uid-a', 'chat-1');
      expect(pending, isNotNull);
      expect(pending!.text, 'OFFLINE test message');
      // The device saw the tile keep the PREVIOUS message's timestamp; the
      // preview and its time must describe the same message.
      expect(pending.timestamp, t0);
    });

    test('the NEWEST of several queued messages wins', () {
      OutboxStore.instance.publish('uid-a', 'chat-1', [
        queued('pending_1', 'first', t0),
        queued('pending_3', 'third', t0.add(const Duration(seconds: 20))),
        queued('pending_2', 'second', t0.add(const Duration(seconds: 10))),
      ]);
      expect(
        OutboxStore.instance.pendingFor('uid-a', 'chat-1')!.text,
        'third',
      );
    });

    test('a chat with nothing queued has no pending preview', () {
      expect(OutboxStore.instance.pendingFor('uid-a', 'chat-1'), isNull);
    });

    test('delivery clears the preview — publishing an empty queue', () {
      OutboxStore.instance.publish('uid-a', 'chat-1', [
        queued('pending_1', 'OFFLINE test message', t0),
      ]);
      expect(OutboxStore.instance.pendingFor('uid-a', 'chat-1'), isNotNull);
      OutboxStore.instance.publish('uid-a', 'chat-1', const []);
      expect(OutboxStore.instance.pendingFor('uid-a', 'chat-1'), isNull);
    });

    test('the list is told to repaint when the queue changes', () {
      var notifications = 0;
      void listener() => notifications++;
      OutboxStore.instance.addListener(listener);
      addTearDown(() => OutboxStore.instance.removeListener(listener));

      OutboxStore.instance.publish('uid-a', 'chat-1', [
        queued('pending_1', 'hello', t0),
      ]);
      expect(notifications, 1);
      OutboxStore.instance.publish('uid-a', 'chat-1', const []);
      expect(notifications, 2);
      // Clearing an already-empty chat is not a change and must not repaint.
      OutboxStore.instance.publish('uid-a', 'chat-1', const []);
      expect(notifications, 2);
    });
  });

  group('waiting is not failing', () {
    test('a queued message is not reported as a failure', () {
      OutboxStore.instance.publish('uid-a', 'chat-1', [
        queued('pending_1', 'hello', t0),
      ]);
      expect(OutboxStore.instance.hasFailure('uid-a', 'chat-1'), isFalse);
    });

    test('a failed message is', () {
      OutboxStore.instance.publish('uid-a', 'chat-1', [
        queued('pending_1', 'hello', t0, status: OutboxStatus.failed),
      ]);
      expect(OutboxStore.instance.hasFailure('uid-a', 'chat-1'), isTrue);
    });

    test('every unsent status counts as unsent', () {
      expect(OutboxStatus.isUnsent(OutboxStatus.queued), isTrue);
      expect(OutboxStatus.isUnsent(OutboxStatus.sending), isTrue);
      expect(OutboxStatus.isUnsent(OutboxStatus.failed), isTrue);
      expect(OutboxStatus.isUnsent('sent'), isFalse);
      expect(OutboxStatus.isUnsent('seen'), isFalse);
    });
  });

  group('ONE MESSAGE, ONE SENDER', () {
    // ChatScreen sends for the thread on screen; the store drains every other
    // thread on the reconnect edge. Without a shared claim those are two
    // senders for the same row, which is how one message becomes two.
    test('a second claim on the same message is refused', () {
      expect(OutboxStore.instance.claimSend('pending_1'), isTrue);
      expect(OutboxStore.instance.claimSend('pending_1'), isFalse);
      expect(OutboxStore.instance.isSending('pending_1'), isTrue);
    });

    test('releasing allows a later retry', () {
      OutboxStore.instance.claimSend('pending_1');
      OutboxStore.instance.releaseSend('pending_1');
      expect(OutboxStore.instance.isSending('pending_1'), isFalse);
      expect(OutboxStore.instance.claimSend('pending_1'), isTrue);
    });

    test('claims do not survive a session boundary', () {
      OutboxStore.instance.claimSend('pending_1');
      OutboxStore.instance.resetForSignOut();
      expect(OutboxStore.instance.isSending('pending_1'), isFalse);
    });
  });

  group('user isolation', () {
    test("one account cannot read another account's queue", () {
      OutboxStore.instance.publish('uid-a', 'chat-1', [
        queued('pending_1', 'private to A', t0),
      ]);
      expect(OutboxStore.instance.pendingFor('uid-b', 'chat-1'), isNull);
      expect(OutboxStore.instance.hasFailure('uid-b', 'chat-1'), isFalse);
    });

    test('a write from a second account is refused, not merged', () {
      OutboxStore.instance.publish('uid-a', 'chat-1', [
        queued('pending_1', 'A', t0),
      ]);
      OutboxStore.instance.publish('uid-b', 'chat-1', [
        queued('pending_2', 'B', t0),
      ]);
      expect(OutboxStore.instance.pendingFor('uid-a', 'chat-1')!.text, 'A');
    });

    test('an empty uid is never an owner', () {
      OutboxStore.instance.publish('', 'chat-1', [
        queued('pending_1', 'nobody', t0),
      ]);
      expect(OutboxStore.instance.pendingFor('', 'chat-1'), isNull);
    });

    test('sign-out drops every queue', () {
      OutboxStore.instance.publish('uid-a', 'chat-1', [
        queued('pending_1', 'A', t0),
      ]);
      OutboxStore.instance.resetForSignOut();
      expect(OutboxStore.instance.pendingFor('uid-a', 'chat-1'), isNull);
      expect(OutboxStore.instance.queueFor('chat-1'), isEmpty);
    });
  });
}
