import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/chat_job_stage.dart';
import 'package:help24/models/chat_presentation.dart';
import 'package:help24/models/job_lifecycle.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/services/delivery_receipts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The chat's presentation rules — which tick, which corner, which day, which
/// stage — checked without a widget tree. See `chat_presentation.dart` and
/// `chat_job_stage.dart`.
void main() {
  Message msg({
    String id = 'a0b1c2d3-0000-4000-8000-000000000001',
    bool mine = true,
    required DateTime t,
    String status = 'sent',
    DateTime? deliveredAt,
    DateTime? seenAt,
    String type = 'text',
    String text = 'hi',
    DateTime? liveUntil,
  }) =>
      Message(
        id: id,
        senderId: mine ? 'me' : 'them',
        text: text,
        timestamp: t,
        isMe: mine,
        status: status,
        deliveredAt: deliveredAt,
        seenAt: seenAt,
        type: type,
        liveUntil: liveUntil,
        latitude: type.contains('location') ? -1.2 : null,
        longitude: type.contains('location') ? 36.8 : null,
      );

  final t0 = DateTime(2026, 10, 4, 13, 15);

  group('sending state', () {
    test('an outbox message is queued until it fails', () {
      expect(chatSendStateOf(msg(id: 'pending_x', t: t0, status: 'queued')), ChatSendState.queued);
      // A request in flight is still "queued" to the reader: the clock, and
      // the attachment's own progress ring.
      expect(chatSendStateOf(msg(id: 'pending_x', t: t0, status: 'sending')), ChatSendState.queued);
      expect(chatSendStateOf(msg(id: 'pending_x', t: t0, status: 'failed')), ChatSendState.failed);
    });

    test('the server has it: one tick', () {
      expect(chatSendStateOf(msg(t: t0)), ChatSendState.sent);
    });

    test('the recipient\'s phone acknowledged it: delivered', () {
      expect(chatSendStateOf(msg(t: t0, deliveredAt: t0)), ChatSendState.delivered);
    });

    test('read outranks delivered — a late delivered stamp never greys it again', () {
      expect(chatSendStateOf(msg(t: t0, status: 'seen')), ChatSendState.read);
      expect(chatSendStateOf(msg(t: t0, status: 'seen', deliveredAt: t0)), ChatSendState.read);
      expect(chatSendStateOf(msg(t: t0, seenAt: t0)), ChatSendState.read);
    });

    test('delivered_at survives the row and cache round trip', () {
      final row = Message.fromJson({
        'id': 'r1',
        'sender_id': 'me',
        'content': 'hi',
        'created_at': '2026-10-04T10:15:00Z',
        'delivered_at': '2026-10-04T10:15:03Z',
      }, 'me');
      expect(row.deliveredAt, DateTime.utc(2026, 10, 4, 10, 15, 3));
      final back = Message.fromJson(row.toCacheMap(), 'me');
      expect(back.deliveredAt, row.deliveredAt);
      expect(chatSendStateOf(back), ChatSendState.delivered);
    });
  });

  group('runs', () {
    test('same sender within two minutes joins the run', () {
      final a = msg(t: t0);
      final b = msg(id: 'b', t: t0.add(const Duration(minutes: 1, seconds: 59)));
      expect(continuesRun(a, b), isTrue);
    });

    test('two minutes apart, another sender, or another day ends it', () {
      final a = msg(t: t0);
      expect(continuesRun(a, msg(id: 'b', t: t0.add(const Duration(minutes: 2)))), isFalse);
      expect(continuesRun(a, msg(id: 'b', mine: false, t: t0.add(const Duration(seconds: 5)))), isFalse);
      final late = DateTime(2026, 10, 4, 23, 59, 30);
      expect(continuesRun(msg(t: late), msg(id: 'b', t: late.add(const Duration(minutes: 1)))), isFalse);
    });

    test('positions: alone, first, middle, last', () {
      final thread = buildChatThread([
        msg(id: '1', t: t0),
        msg(id: '2', t: t0.add(const Duration(seconds: 20))),
        msg(id: '3', t: t0.add(const Duration(seconds: 40))),
        msg(id: '4', mine: false, t: t0.add(const Duration(minutes: 1))),
      ]);
      final positions = [for (final e in thread.whereType<ChatMessageEntry>()) e.position];
      expect(positions, const [
        RunPosition(first: true, last: false),
        RunPosition(first: false, last: false),
        RunPosition(first: false, last: true),
        RunPosition(first: true, last: true),
      ]);
    });

    test('a day pill starts every local day, and an event breaks a run', () {
      final thread = buildChatThread(
        [
          msg(id: '1', t: DateTime(2026, 10, 3, 22, 0)),
          msg(id: '2', t: DateTime(2026, 10, 4, 9, 0)),
          msg(id: '3', t: DateTime(2026, 10, 4, 9, 1)),
        ],
        extraEvents: [
          ChatEvent(kind: ChatEventKind.paidHeld, at: DateTime(2026, 10, 4, 9, 0, 30), label: 'paid'),
        ],
      );
      expect(thread.map((e) => e.runtimeType).toList(), [
        ChatDayEntry, ChatMessageEntry, ChatDayEntry, ChatMessageEntry, ChatEventEntry, ChatMessageEntry,
      ]);
      final last = thread.last as ChatMessageEntry;
      expect(last.position.first, isTrue, reason: 'the event between them ends the run');
    });

    test('the arrival notice and an arrived journey are events, not bubbles', () {
      final thread = buildChatThread([
        msg(id: '1', mine: false, t: t0, text: kArrivalNoticeText),
        msg(id: '2', mine: false, t: t0, type: 'live_location', text: 'Arrived', liveUntil: t0),
        msg(id: '3', t: t0, text: 'ok'),
      ], partnerName: 'Joseph');
      final events = thread.whereType<ChatEventEntry>().map((e) => e.event).toList();
      expect(events.length, 2);
      expect(events.every((e) => e.kind == ChatEventKind.arrived && e.label == 'Joseph arrived'), isTrue);
      expect(thread.whereType<ChatMessageEntry>().length, 1);
    });

    test('an offer sits where it was made', () {
      final thread = buildChatThread(
        [msg(id: '1', t: t0)],
        offers: [
          ChatThreadOffer(id: 'o', mine: true, price: 1100, at: t0.subtract(const Duration(hours: 1)), status: ChatOfferStatus.pending),
        ],
      );
      expect(thread[1], isA<ChatOfferEntry>());
      expect(thread[2], isA<ChatMessageEntry>());
    });
  });

  group('time and day labels', () {
    final now = DateTime(2026, 10, 4, 15, 0); // a Sunday

    test('Today, Yesterday, the weekday within the week, then the date', () {
      expect(chatDayLabel(DateTime(2026, 10, 4, 0, 1), now: now), 'Today');
      expect(chatDayLabel(DateTime(2026, 10, 3, 23, 59), now: now), 'Yesterday');
      expect(chatDayLabel(DateTime(2026, 10, 1, 9), now: now), 'Thursday');
      expect(chatDayLabel(DateTime(2026, 9, 28, 9), now: now), 'Monday');
      expect(chatDayLabel(DateTime(2026, 9, 27, 9), now: now), '27 Sep', reason: 'seven days back is a date');
    });

    test('the year appears only when it is not this year', () {
      expect(chatDayLabel(DateTime(2026, 1, 25), now: now), '25 Jan');
      expect(chatDayLabel(DateTime(2025, 9, 25), now: now), '25 Sep 2025');
    });

    test('message info carries the full date and time', () {
      final t = DateTime(2026, 9, 29, 13, 15);
      expect(chatInfoStamp(t, use24Hour: false), 'Tuesday 29 Sep 2026 at 1:15 PM');
      expect(chatInfoStamp(t, use24Hour: true), 'Tuesday 29 Sep 2026 at 13:15');
      expect(chatInfoStamp(DateTime(2026, 9, 29, 0, 5), use24Hour: false), 'Tuesday 29 Sep 2026 at 12:05 AM');
    });
  });

  group('file line', () {
    test('type, then pages and size only when known', () {
      expect(chatFileMetaLine('contract.pdf', pages: 2, bytes: 151552), 'PDF · 2 pages · 148 KB');
      expect(chatFileMetaLine('contract.pdf', bytes: 151552), 'PDF · 148 KB');
      expect(chatFileMetaLine('contract.pdf'), 'PDF');
      expect(chatFileMetaLine('cv.docx', pages: 1), 'DOC · 1 page');
      expect(chatFileMetaLine('scan.TIFF'), 'TIFF');
    });

    test('sizes', () {
      expect(formatFileSize(820), '820 B');
      expect(formatFileSize(1536), '2 KB');
      expect(formatFileSize(1258291), '1.2 MB');
    });
  });

  group('who the other person is', () {
    test('read off the post: the author of a request is the customer', () {
      expect(
        chatPartnerRoleOf(viewerId: 'me', partnerId: 'them', postAuthorId: 'them'),
        ChatPartnerRole.customer,
      );
      expect(
        chatPartnerRoleOf(viewerId: 'me', partnerId: 'them', postAuthorId: 'me'),
        ChatPartnerRole.provider,
      );
      expect(
        chatPartnerRoleOf(viewerId: 'me', partnerId: 'them', postAuthorId: 'them', postIsOffer: true),
        ChatPartnerRole.provider,
      );
    });

    test('without a post, a profession makes a provider', () {
      expect(chatPartnerRoleOf(viewerId: 'me', partnerId: 'them', partnerHasProfession: true), ChatPartnerRole.provider);
      expect(chatPartnerRoleOf(viewerId: 'me', partnerId: 'them'), ChatPartnerRole.unknown);
    });

    test('the header line uses what exists, or nothing (presence takes over)', () {
      expect(
        chatPartnerLine(role: ChatPartnerRole.provider, professionLabel: 'Plumber', rating: 4.8, completedJobs: 34),
        'Plumber · ★ 4.8 · 34 jobs',
      );
      expect(chatPartnerLine(role: ChatPartnerRole.provider, completedJobs: 1), 'Provider · 1 job');
      expect(chatPartnerLine(role: ChatPartnerRole.provider), isNull);
      expect(chatPartnerLine(role: ChatPartnerRole.customer, area: 'Bamburi, Mombasa'), 'Customer · Bamburi, Mombasa');
      expect(chatPartnerLine(role: ChatPartnerRole.customer, area: ' '), isNull);
      expect(chatPartnerLine(role: ChatPartnerRole.unknown, professionLabel: 'Plumber'), isNull);
    });
  });

  group('pinned job bar', () {
    JobLifecycle lc(String state, {String role = 'client', String? completion}) => JobLifecycle.fromJson({
          'post': {'id': 'p', 'title': 'Sink', 'price': 1100, 'author_user_id': 'x'},
          'viewer_role': role,
          'settlement': {'state': state},
          'payment': {'amount': 1100},
          if (completion != null) 'completion': {'status': completion},
        });

    ChatJobBarState bar({
      bool client = true,
      String? selected = 'them',
      JobLifecycle? life,
      DateTime? arrived,
      List<ChatJobOffer> offers = const [],
    }) =>
        deriveChatJobBar(ChatJobInputs(
          viewerId: 'me',
          partnerId: 'them',
          partnerName: 'Joseph',
          title: 'Sink',
          price: 1100,
          authorId: client ? 'me' : 'them',
          selectedProviderId: selected == null ? null : (client ? selected : 'me'),
          offers: offers,
          lifecycle: life,
          arrivedAt: arrived,
          arrivalClock: arrived == null ? null : '11:27 AM',
        ));

    test('an offer on the table: Review for the customer', () {
      final s = bar(selected: null, offers: [ChatJobOffer(applicantId: 'them', price: 1100, at: t0)]);
      expect(s.stage, ChatJobStage.offerIn);
      expect(s.status, 'Joseph offered KES 1,100');
      expect((s.action, s.primary), (ChatJobAction.review, true));
      expect(s.segments.first, ChatJobSegment.current);
    });

    test('price agreed: the customer pays with M-Pesa — the only rail there is', () {
      final s = bar(life: lc('awaiting_payment'));
      expect(s.stage, ChatJobStage.priceAgreed);
      expect(s.status, 'KES 1,100 · Pay with M-Pesa');
      expect(s.action, ChatJobAction.pay);
      expect(s.segments, [ChatJobSegment.done, ChatJobSegment.current, ChatJobSegment.track, ChatJobSegment.track]);
    });

    test('held: Details for the customer, "I\'ve arrived" for the provider', () {
      final customer = bar(life: lc('in_escrow'));
      expect(customer.status, 'KES 1,100 held by Help24');
      expect((customer.action, customer.primary), (ChatJobAction.details, false));
      expect(customer.tone, ChatJobTone.success);
      final provider = bar(client: false, life: lc('in_escrow', role: 'provider'));
      expect(provider.status, 'KES 1,100 held by Help24');
      expect((provider.action, provider.actionLabel), (ChatJobAction.imArrived, "I've arrived"));
      expect(provider.segments, [ChatJobSegment.done, ChatJobSegment.done, ChatJobSegment.track, ChatJobSegment.track]);
    });

    test('arrived: the provider marks it complete; the customer cannot yet', () {
      final provider = bar(client: false, life: lc('in_escrow', role: 'provider'), arrived: t0);
      expect(provider.stage, ChatJobStage.arrived);
      expect(provider.action, ChatJobAction.markComplete);
      final customer = bar(life: lc('in_escrow'), arrived: t0);
      expect(customer.status, 'Joseph arrived at 11:27 AM');
      // The server's approve needs the provider's completion first.
      expect(customer.action, ChatJobAction.details);
    });

    test('the provider marked it done: the customer\'s "Mark complete" approves', () {
      final s = bar(life: lc('in_escrow', completion: 'pending_approval'));
      expect(s.stage, ChatJobStage.completionPending);
      expect((s.action, s.actionLabel, s.primary), (ChatJobAction.approve, 'Mark complete', true));
    });

    test('released, and a payout still on its way is never called released', () {
      final released = bar(life: lc('released'));
      expect(released.status, 'KES 1,100 released to Joseph');
      expect(released.action, ChatJobAction.rate);
      expect(released.segments.every((s) => s == ChatJobSegment.done), isTrue);
      final paying = bar(life: lc('payout_processing'));
      expect(paying.stage, ChatJobStage.payoutProcessing);
      expect(paying.status, isNot(contains('released')));
      expect(paying.segments.last, ChatJobSegment.current);
    });

    test('dispute: on hold, in danger', () {
      final s = bar(life: lc('disputed'));
      expect(s.status, 'Payment on hold: dispute open');
      expect(s.segments[2], ChatJobSegment.danger);
      expect(s.tone, ChatJobTone.danger);
    });

    test('what cannot be derived falls back to title, price and View', () {
      for (final s in [
        bar(), // lifecycle not loaded
        bar(selected: null), // nobody selected, no offer from this person
        bar(life: lc('something_new')), // a state this build does not know
      ]) {
        expect(s.stage, ChatJobStage.unknown);
        expect((s.title, s.status, s.action), ('Sink', 'KES 1,100', ChatJobAction.view));
      }
    });

    test('a chat with someone who was NOT selected is not that job', () {
      final s = deriveChatJobBar(ChatJobInputs(
        viewerId: 'me',
        partnerId: 'other',
        partnerName: 'Other',
        title: 'Sink',
        price: 1100,
        authorId: 'me',
        selectedProviderId: 'joseph',
        lifecycle: lc('in_escrow'),
      ));
      expect(s.stage, ChatJobStage.unknown);
    });
  });

  group('delivered receipts', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      DeliveryReceipts.resetForTest();
    });

    test('the acknowledgement touches only messages FROM the other person, never overwriting', () {
      final uri = DeliveryReceipts.ackUri(chatId: 'c-1', uid: 'u-9');
      expect(uri.queryParameters['chat_id'], 'eq.c-1');
      expect(uri.queryParameters['sender_id'], 'neq.u-9');
      expect(uri.queryParameters['delivered_at'], 'is.null');
    });

    test('a server without the column is recognised', () {
      expect(DeliveryReceipts.isMissingColumn(code: '42703'), isTrue);
      expect(DeliveryReceipts.isMissingColumn(code: 'PGRST204'), isTrue);
      expect(
        DeliveryReceipts.isMissingColumn(message: "Could not find the 'delivered_at' column of 'chat_messages'"),
        isTrue,
      );
      expect(DeliveryReceipts.isMissingColumn(code: '42501', message: 'permission denied'), isFalse);
    });

    test('a chat is acknowledged once per new message, not on every list refresh', () async {
      final writes = <List<String>>[];
      DeliveryReceipts.writeOverride = (uid, chats, at) async => writes.add(chats);
      final first = DateTime.utc(2026, 10, 4, 10);
      await DeliveryReceipts.acknowledge(uid: 'me', chatIds: ['a', 'b'], newest: {'a': first, 'b': first});
      await DeliveryReceipts.acknowledge(uid: 'me', chatIds: ['a', 'b'], newest: {'a': first, 'b': first});
      await DeliveryReceipts.acknowledge(
        uid: 'me',
        chatIds: ['a', 'b'],
        newest: {'a': first.add(const Duration(minutes: 1)), 'b': first},
      );
      expect(writes, [
        ['a', 'b'],
        ['a'],
      ]);
    });

    test('after the server refuses the column, it stops asking for a while', () async {
      SharedPreferences.setMockInitialValues({
        'chat.delivered_receipts.unavailable_at': DateTime.now().millisecondsSinceEpoch,
      });
      var writes = 0;
      DeliveryReceipts.writeOverride = (_, __, ___) async => writes++;
      await DeliveryReceipts.acknowledge(uid: 'me', chatIds: ['a']);
      expect(writes, 0);
    });
  });
}
