import 'dart:io' as io;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/chat_job_stage.dart';
import 'package:help24/models/chat_presentation.dart';
import 'package:help24/models/job_lifecycle.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/services/chat_attachments.dart';
import 'package:help24/services/place_name_cache.dart';
import 'package:help24/theme/tokens.dart';
import 'package:help24/widgets/chat/chat_bubbles.dart';
import 'package:help24/widgets/chat/chat_chrome.dart';
import 'package:help24/widgets/location_experience.dart';

import 'support/chat_fixtures.dart';
import 'support/chat_shot_harness.dart';

/// THE REDESIGN, RENDERED: every chat surface the brief lists, in both themes.
///
/// Three things are checked for each scene, and the screenshots for the
/// before/after report come out of the same runs (`--dart-define=
/// CHAT_SHOTS_DIR=<dir>` to write them):
///
///   * LIGHT AND DARK ARE THE SAME COMPONENT. Every render box in the scene —
///     its type, position and size — is identical in both themes; only paint
///     may differ. A brightness branch that moved or resized anything fails.
///   * LARGE SYSTEM TEXT GROWS, IT DOES NOT CLIP. At 130% and 200% nothing
///     overflows, and no paragraph is squeezed below its own text height.
///   * Nothing throws while laying any of it out.
void main() {
  setUpAll(() async {
    await loadAppFonts();
    // No platform geocoder in a test: the area the phone would name.
    PlaceNameCache.debugSeed(-1.2345, 36.8312, 'Karura Forest');
    MapThumbnail.debugBuilder =
        (context, _, __) => FixtureMap(night: ChatColors.of(context).mapStyle != null);
  });

  late String queuedPhotoPath;
  var prepared = false;

  Future<void> prepare(WidgetTester tester) async {
    if (prepared) return;
    final Uint8List bytes = (await tester.runAsync(() => fixturePhotoPng()))!;
    ChatAttachmentCache.instanceForTest =
        (await tester.runAsync(() => FixtureImageCache.create(bytes)))!;
    await tester.runAsync(() async {
      final dir = await io.Directory.systemTemp.createTemp('chat_shots');
      final f = io.File('${dir.path}/queued.png');
      await f.writeAsBytes(bytes);
      queuedPhotoPath = f.path;
    });
    prepared = true;
  }

  const alone = RunPosition(first: true, last: true);

  Widget frame(Brightness b, Widget child, {double textScale = 1, bool padded = true}) => ShotFrame(
        brightness: b,
        textScale: textScale,
        background: (b == Brightness.dark ? ChatColors.dark : ChatColors.light).bg,
        child: padded
            ? Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: ChatGeometry.sidePadding, vertical: 12),
                child: child,
              )
            : child,
      );

  Widget mine(Widget w) => Align(alignment: AlignmentDirectional.centerEnd, child: w);
  Widget theirs(Widget w) => Align(alignment: AlignmentDirectional.centerStart, child: w);
  Widget gap([double h = ChatGeometry.betweenGroupsGap]) => SizedBox(height: h);
  Widget col(List<Widget> c) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: c);

  Widget text(Message m, {RunPosition p = alone}) => Builder(
        builder: (context) => ChatTextBubble(
          message: m,
          position: p,
          time: chatBubbleTime(context, m.timestamp),
          state: m.isMe ? chatSendStateOf(m) : null,
        ),
      );

  // Every row is built by the same widget the thread uses, long-press wired,
  // so a fault in how rows are composed fails here and not on a phone.
  Widget framed(Message m, Widget bubble, {RunPosition p = const RunPosition(first: false, last: true)}) =>
      ChatMessageRow(
        mine: m.isMe,
        position: p,
        state: m.isMe ? chatSendStateOf(m) : null,
        onLongPress: (_) {},
        onRetry: () {},
        bubble: bubble,
      );

  JobLifecycle lifecycle(String state, {String role = 'client', String? completion, List<Map<String, dynamic>> timeline = const []}) =>
      JobLifecycle.fromJson({
        'post': {
          'id': 'p1',
          'title': 'Leaking kitchen sink',
          'price': 1100,
          'status': 'assigned',
          'author_user_id': role == 'client' ? 'me' : 'them',
          'selected_provider_id': role == 'client' ? 'them' : 'me',
        },
        'viewer_role': role,
        'settlement': {'state': state, 'label': '', 'explanation': ''},
        'payment': {'transaction_id': 't1', 'status': 'paid', 'amount': 1100},
        if (completion != null) 'completion': {'id': 'c1', 'status': completion},
        'timeline': timeline,
      });

  ChatJobBarState bar({
    required bool client,
    String? selected,
    JobLifecycle? lc,
    DateTime? arrivedAt,
    List<ChatJobOffer> offers = const [],
  }) =>
      deriveChatJobBar(ChatJobInputs(
        viewerId: 'me',
        partnerId: 'them',
        partnerName: client ? 'Joseph' : 'Amina',
        title: 'Leaking kitchen sink',
        price: 1100,
        authorId: client ? 'me' : 'them',
        selectedProviderId: selected,
        offers: offers,
        lifecycle: lc,
        arrivedAt: arrivedAt,
        arrivalClock: arrivedAt == null ? null : '11:27 AM',
      ));

  Widget jobBar(ChatJobBarState s) => ChatJobBar(state: s, onOpen: () {}, onAction: () {});

  final placeTime = ChatFixtures.at(13, 6);

  final scenes = <String, Widget Function()>{
    'text': () => col([
          theirs(text(ChatFixtures.text('Hello', mine: false, t: ChatFixtures.at(2, 43)))),
          gap(),
          framed(
            ChatFixtures.text('Can you come tomorrow? - offline test', mine: true, t: ChatFixtures.at(13, 15)),
            text(ChatFixtures.text('Can you come tomorrow? - offline test', mine: true, t: ChatFixtures.at(13, 15))),
          ),
          gap(),
          theirs(text(ChatFixtures.text(
              'The cabinet floor is already soft, so please come as early as you can. The gate code is 4471.',
              mine: false,
              t: ChatFixtures.at(10, 43)))),
        ]),
    'grouped': () {
      final a = ChatFixtures.text('Can you come tomorrow?', mine: true, t: ChatFixtures.at(13, 15));
      final b = ChatFixtures.text('The gate code is 4471.', mine: true, t: ChatFixtures.at(13, 15, second: 20));
      final c = ChatFixtures.text('Ring when you are outside.', mine: true, t: ChatFixtures.at(13, 16));
      final d = ChatFixtures.text('Sure, I will be there by 9.', mine: false, t: ChatFixtures.at(13, 18));
      final e = ChatFixtures.text('Bringing the new trap.', mine: false, t: ChatFixtures.at(13, 18, second: 30));
      final entries = buildChatThread([a, b, c, d, e]).whereType<ChatMessageEntry>().toList();
      return col([
        for (final entry in entries) ...[
          gap(entry.position.first ? ChatGeometry.betweenGroupsGap : ChatGeometry.inGroupGap),
          entry.message.isMe
              ? mine(text(entry.message, p: entry.position))
              : theirs(text(entry.message, p: entry.position)),
        ],
      ]);
    },
    'photo': () {
      final m = ChatFixtures.photo(mine: true, t: ChatFixtures.at(13, 3));
      return framed(m, Builder(builder: (context) => ChatPhotoBubble(message: m, position: alone, time: '1:03 PM', state: chatSendStateOf(m), onOpen: () {})));
    },
    'photo_caption': () {
      final m = ChatFixtures.photo(mine: true, t: ChatFixtures.at(13, 3), caption: 'The leak is under the sink');
      return framed(m, ChatPhotoBubble(message: m, position: alone, time: '1:03 PM', state: chatSendStateOf(m), onOpen: () {}));
    },
    'location_sent': () {
      final m = ChatFixtures.place('Front Gate', mine: true, t: placeTime);
      return framed(m, ChatLocationBubble(message: m, position: alone, time: '1:06 PM', state: chatSendStateOf(m), onOpen: () {}));
    },
    'location_received': () {
      final m = ChatFixtures.place('Blue gate', mine: false, t: ChatFixtures.at(10, 46));
      return framed(
        m,
        ChatLocationBubble(
          message: m,
          position: alone,
          time: '10:46 AM',
          viewerLat: ChatFixtures.viewerLat,
          viewerLng: ChatFixtures.viewerLng,
          onOpen: () {},
        ),
      );
    },
    'file': () {
      final out = ChatFixtures.file(mine: true, t: ChatFixtures.at(13, 15), status: 'seen');
      final inc = ChatFixtures.file(mine: false, t: ChatFixtures.at(13, 18), name: 'quote_kitchen_sink_final_signed.docx');
      ChatFileSizes.remember(out.id, 151552);
      return col([
        framed(out, ChatFileBubble(message: out, position: alone, time: '1:15 PM', state: chatSendStateOf(out), onOpen: () {})),
        gap(),
        framed(inc, ChatFileBubble(message: inc, position: alone, time: '1:18 PM', onOpen: () {})),
      ]);
    },
    'states': () {
      final t = ChatFixtures.at(13, 15);
      final queued = ChatFixtures.pending('Can you come tomorrow?', t: t, status: 'queued');
      final sent = ChatFixtures.text('Can you come tomorrow?', mine: true, t: t);
      final delivered = ChatFixtures.text('Can you come tomorrow?', mine: true, t: t, deliveredAt: t);
      final read = ChatFixtures.text('Can you come tomorrow?', mine: true, t: t, status: 'seen');
      final failed = ChatFixtures.pending('Can you come tomorrow?', t: t, status: 'failed');
      final uploading = ChatFixtures.pending('Image', t: t, status: 'sending', type: 'image', localPath: queuedPhotoPath);
      return col([
        for (final m in [queued, sent, delivered, read, failed]) ...[framed(m, text(m)), gap(10)],
        framed(
          uploading,
          ChatPhotoBubble(
            message: uploading,
            position: alone,
            time: '1:15 PM',
            state: chatSendStateOf(uploading),
            localPath: queuedPhotoPath,
            onCancel: () {},
          ),
        ),
      ]);
    },
    'offline_banner': () => const ChatOfflineBanner(),
    'job_bar_offer': () => jobBar(bar(
          client: true,
          offers: [ChatJobOffer(applicantId: 'them', price: 1100, at: ChatFixtures.at(9, 0))],
        )),
    'job_bar_agreed': () => jobBar(bar(client: true, selected: 'them', lc: lifecycle('awaiting_payment'))),
    'job_bar_held': () => jobBar(bar(client: true, selected: 'them', lc: lifecycle('in_escrow'))),
    'job_bar_held_provider': () =>
        jobBar(bar(client: false, selected: 'me', lc: lifecycle('in_escrow', role: 'provider'))),
    'job_bar_arrived': () => jobBar(bar(
          client: false,
          selected: 'me',
          lc: lifecycle('in_escrow', role: 'provider'),
          arrivedAt: ChatFixtures.at(11, 27),
        )),
    'job_bar_complete': () =>
        jobBar(bar(client: true, selected: 'them', lc: lifecycle('in_escrow', completion: 'pending_approval'))),
    'job_bar_released': () => jobBar(bar(client: true, selected: 'them', lc: lifecycle('released'))),
    'job_bar_dispute': () => jobBar(bar(client: true, selected: 'them', lc: lifecycle('disputed'))),
    'job_bar_fallback': () => jobBar(bar(client: true, selected: 'them')),
    'composer_empty': () => ChatComposer(
          controller: TextEditingController(),
          onAttach: () {},
          onCamera: () {},
          onSend: () {},
        ),
    'composer_typing': () => ChatComposer(
          controller: TextEditingController(text: 'Main Entrance, by the guard hut'),
          onAttach: () {},
          onCamera: () {},
          onSend: () {},
        ),
    'date_divider': () => col([
          Center(child: ChatDayPill(label: chatDayLabel(ChatFixtures.at(9, 0, daysAgo: 3)))),
          gap(12),
          Center(
            child: ChatEventPill(
              event: ChatEvent(
                kind: ChatEventKind.paidHeld,
                at: ChatFixtures.at(10, 42),
                label: 'Amina paid. KES 1,100 is held by Help24',
              ),
              time: '10:42 AM',
            ),
          ),
          gap(12),
          Center(
            child: ChatEventPill(
              event: ChatEvent(kind: ChatEventKind.arrived, at: ChatFixtures.at(11, 27), label: 'Joseph arrived'),
              time: '11:27 AM',
            ),
          ),
        ]),
    'offer_card': () => mine(ChatOfferCard(
          offer: ChatThreadOffer(
            id: 'a1',
            mine: true,
            price: 1100,
            at: ChatFixtures.at(10, 41),
            status: ChatOfferStatus.accepted,
            acceptedBy: 'Amina',
            message: 'I can be there within the hour. Price includes the replacement trap.',
          ),
          time: '10:41 AM',
        )),
    'header': () => col([
          ChatHeader(
            name: 'Alphonse Lincoln',
            avatarUrl: '',
            subtitle: 'Plumber · ★ 4.8 · 34 jobs',
            online: true,
            onBack: () {},
            menu: ChatMenuButton<int>(itemBuilder: (_) => const [], onSelected: (_) {}),
          ),
          ChatHeader(
            name: 'Amina Yusuf',
            avatarUrl: '',
            subtitle: 'Customer · Bamburi, Mombasa',
            onBack: () {},
            menu: ChatMenuButton<int>(itemBuilder: (_) => const [], onSelected: (_) {}),
          ),
        ]),
    'scroll_button': () => Align(
          alignment: AlignmentDirectional.centerEnd,
          child: ChatScrollToLatest(onTap: () {}, unread: 3),
        ),
    'quick_replies': () => ChatQuickReplies(replies: ChatQuickReplies.onTheWay, onTap: (_) {}),
  };

  // The rows a real thread holds that the canvas does not show: messages
  // deleted for everyone, a location request, a journey that ended. The S20+
  // thread that exposed the row-recursion bug was mostly the first kind.
  scenes['thread_rows'] = () {
    final t = ChatFixtures.at(8, 37);
    final mineGone = Message(
        id: 'f0f0f0f0-0000-4000-8000-000000000001', senderId: 'me', text: 'Help24 offline-delete test.pdf',
        timestamp: t, isMe: true, type: 'file', status: 'seen', deletedForEveryone: true);
    final theirsGone = Message(
        id: 'f0f0f0f0-0000-4000-8000-000000000002', senderId: 'them', text: 'Photo',
        timestamp: t, isMe: false, type: 'image', deletedForEveryone: true);
    final ask = Message(
        id: 'f0f0f0f0-0000-4000-8000-000000000003', senderId: 'them', text: 'Location requested',
        timestamp: t, isMe: false, type: 'location_request');
    final ended = Message(
        id: 'f0f0f0f0-0000-4000-8000-000000000004', senderId: 'them', text: 'On my way', timestamp: t,
        isMe: false, type: 'live_location', latitude: -1.2, longitude: 36.8,
        liveUntil: t.subtract(const Duration(minutes: 5)));
    return Builder(
      builder: (context) => col([
        framed(mineGone, ChatTombstoneBubble(message: mineGone, position: alone, time: '8:37 AM')),
        framed(theirsGone, ChatTombstoneBubble(message: theirsGone, position: alone, time: '8:37 AM')),
        framed(
          ask,
          ChatCardBubble(
            message: ask,
            position: alone,
            time: '8:37 AM',
            child: RequestCard(message: ask, partnerName: 'Joseph', onShareNow: () {}),
          ),
        ),
        framed(
          ended,
          ChatCardBubble(
            message: ended,
            position: alone,
            time: '8:37 AM',
            child: JourneyCard(message: ended, width: ChatCardBubble.innerWidth(context)),
          ),
        ),
      ]),
    );
  };

  testWidgets('a row reports its bubble on long-press, once, without rebuilding itself', (tester) async {
    await prepare(tester);
    final m = ChatFixtures.text('Hold me', mine: true, t: ChatFixtures.at(9, 0));
    final rects = <Rect>[];
    await pumpShot(
      tester,
      frame(
        Brightness.light,
        ChatMessageRow(
          mine: true,
          position: alone,
          state: ChatSendState.sent,
          onLongPress: rects.add,
          bubble: KeyedSubtree(key: const ValueKey('bubble'), child: text(m)),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(GestureDetector), findsWidgets);
    await tester.longPress(find.byKey(const ValueKey('bubble')));
    expect(rects, hasLength(1));
    expect(rects.single, tester.getRect(find.byKey(const ValueKey('bubble'))));
  });

  // The whole screen, composed from the shipped components — the canvas's two
  // phones, message for message.
  Widget phone(List<Widget> top, List<Widget> thread, List<Widget> bottom, {int daysAgo = 1}) => SizedBox(
        height: 867,
        child: Builder(
          builder: (context) => Column(
            children: [
              const SizedBox(height: 32),
              ...top,
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: SingleChildScrollView(
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(ChatGeometry.sidePadding, 6, ChatGeometry.sidePadding, 6),
                        child: col(thread),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      left: 0,
                      right: 0,
                      child: Center(child: ChatDayPill(label: chatDayLabel(ChatFixtures.at(9, 0, daysAgo: daysAgo)))),
                    ),
                  ],
                ),
              ),
              ...bottom,
              const SizedBox(height: 19),
            ],
          ),
        ),
      );

  scenes['screen_main'] = () {
    final photo = ChatFixtures.photo(mine: true, t: ChatFixtures.at(13, 3, daysAgo: 1));
    final gate = ChatFixtures.place('Front Gate', mine: true, t: ChatFixtures.at(13, 6, daysAgo: 1));
    final note = ChatFixtures.text('Can you come tomorrow? - offline test', mine: true, t: ChatFixtures.at(13, 15, daysAgo: 1));
    final pdf = ChatFixtures.file(mine: true, t: ChatFixtures.at(13, 15, daysAgo: 1, second: 10));
    final entrance = ChatFixtures.place('Main Entrance', mine: true, t: ChatFixtures.at(13, 15, daysAgo: 1, second: 40));
    ChatFileSizes.remember(pdf.id, 151552);
    final entries = buildChatThread([photo, gate, note, pdf, entrance]).whereType<ChatMessageEntry>().toList();
    Widget row(ChatMessageEntry e) {
      final m = e.message;
      final time = '${m.timestamp.hour % 12 == 0 ? 12 : m.timestamp.hour % 12}:${m.timestamp.minute.toString().padLeft(2, '0')} PM';
      final s = chatSendStateOf(m);
      final Widget b = switch (m.type) {
        'image' => ChatPhotoBubble(message: m, position: e.position, time: time, state: s, onOpen: () {}),
        'location' => ChatLocationBubble(message: m, position: e.position, time: time, state: s, onOpen: () {}),
        'file' => ChatFileBubble(message: m, position: e.position, time: time, state: s, onOpen: () {}),
        _ => ChatTextBubble(message: m, position: e.position, time: time, state: s),
      };
      return framed(m, b, p: e.position);
    }

    return phone(
      [
        ChatHeader(
          name: 'Alphonse Lincoln',
          avatarUrl: '',
          subtitle: 'last seen 21h ago',
          onBack: () {},
          menu: ChatMenuButton<int>(itemBuilder: (_) => const [], onSelected: (_) {}),
        ),
        jobBar(bar(client: true)),
      ],
      [for (final e in entries) row(e)],
      [
        ChatComposer(controller: TextEditingController(), onAttach: () {}, onCamera: () {}, onSend: () {}),
      ],
    );
  };

  scenes['screen_job'] = () {
    const t = ChatFixtures.at;
    final reply = ChatFixtures.text('Thank you! The cabinet floor is already soft, please hurry.', mine: false, t: t(10, 43));
    final leaving = ChatFixtures.text("Leaving now. I'll be there by 11:30.", mine: true, t: t(10, 44), status: 'seen');
    final pin = ChatFixtures.place('Blue gate', mine: false, t: t(10, 46));
    final ring = ChatFixtures.text("Ring when you're outside, the bell doesn't work.", mine: false, t: t(10, 46, second: 30));
    final thread = buildChatThread(
      [reply, leaving, pin, ring],
      extraEvents: [
        ChatEvent(kind: ChatEventKind.paidHeld, at: t(10, 42), label: 'Amina paid. KES 1,100 is held by Help24'),
      ],
      offers: [
        ChatThreadOffer(
          id: 'a1',
          mine: true,
          price: 1100,
          at: t(10, 41),
          status: ChatOfferStatus.accepted,
          acceptedBy: 'Amina',
          message: 'I can be there within the hour. Price includes the replacement trap.',
        ),
      ],
    );
    Widget row(ChatThreadEntry e) => switch (e) {
          ChatDayEntry() => const SizedBox.shrink(),
          ChatOfferEntry(:final offer) => Padding(
              padding: const EdgeInsets.only(top: ChatGeometry.betweenGroupsGap),
              child: mine(ChatOfferCard(offer: offer, time: '10:41 AM')),
            ),
          ChatEventEntry(:final event) => Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 2),
              child: Center(child: ChatEventPill(event: event, time: '10:42 AM')),
            ),
          ChatMessageEntry(:final message, :final position) => framed(
                message,
                p: position,
                switch (message.type) {
                  'location' => ChatLocationBubble(
                      message: message,
                      position: position,
                      time: '10:46 AM',
                      viewerLat: ChatFixtures.viewerLat,
                      viewerLng: ChatFixtures.viewerLng,
                      onOpen: () {},
                    ),
                  _ => Builder(
                      builder: (context) => ChatTextBubble(
                        message: message,
                        position: position,
                        time: chatBubbleTime(context, message.timestamp),
                        state: message.isMe ? chatSendStateOf(message) : null,
                      ),
                    ),
                },
              ),
        };
    return phone(
      [
        ChatHeader(
          name: 'Amina Yusuf',
          avatarUrl: '',
          subtitle: 'Customer · Bamburi, Mombasa',
          onBack: () {},
          menu: ChatMenuButton<int>(itemBuilder: (_) => const [], onSelected: (_) {}),
        ),
        jobBar(bar(client: false, selected: 'me', lc: lifecycle('in_escrow', role: 'provider'))),
      ],
      [for (final e in thread) row(e)],
      [
        ChatQuickReplies(replies: ChatQuickReplies.onTheWay, onTap: (_) {}),
        ChatComposer(controller: TextEditingController(), onAttach: () {}, onCamera: () {}, onSend: () {}),
      ],
      daysAgo: 0,
    );
  };

  List<String> geometry(WidgetTester tester) {
    final root = tester.renderObject<RenderBox>(find.byKey(const ValueKey('shot')));
    final out = <String>[];
    void visit(RenderObject o) {
      if (o is RenderBox && o.hasSize) {
        final r = o.localToGlobal(Offset.zero) & o.size;
        out.add('${o.runtimeType} ${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)} '
            '${r.width.toStringAsFixed(1)}x${r.height.toStringAsFixed(1)}');
      }
      o.visitChildren(visit);
    }

    visit(root);
    return out;
  }

  List<String> clippedText(WidgetTester tester) {
    final root = tester.renderObject<RenderBox>(find.byKey(const ValueKey('shot')));
    final clipped = <String>[];
    void visit(RenderObject o) {
      if (o is RenderParagraph && o.hasSize) {
        final need = o.getMinIntrinsicHeight(o.size.width);
        final cut = need > o.size.height + 0.5 ||
            (o.didExceedMaxLines && o.overflow == TextOverflow.clip);
        if (cut) clipped.add('"${o.text.toPlainText()}" ${o.size} needs height $need');
      }
      o.visitChildren(visit);
    }

    visit(root);
    return clipped;
  }

  testWidgets('the canvas measurements hold at 390 wide', (tester) async {
    await prepare(tester);
    final hello = ChatFixtures.text('Hello', mine: false, t: ChatFixtures.at(2, 43));
    // Unbroken, so the line fills to the cap rather than stopping at a word.
    final long = ChatFixtures.text('x' * 400, mine: true, t: ChatFixtures.at(13, 15));
    final pic = ChatFixtures.photo(mine: true, t: ChatFixtures.at(13, 3));
    await pumpShot(
      tester,
      frame(
        Brightness.dark,
        col([
          theirs(KeyedSubtree(key: const ValueKey('hello'), child: text(hello))),
          mine(KeyedSubtree(key: const ValueKey('long'), child: text(long))),
          mine(KeyedSubtree(
            key: const ValueKey('photo'),
            child: ChatPhotoBubble(message: pic, position: alone, time: '1:03 PM', state: ChatSendState.sent),
          )),
          Center(child: KeyedSubtree(key: const ValueKey('day'), child: ChatDayPill(label: 'Today'))),
          Center(
            child: KeyedSubtree(
              key: const ValueKey('event'),
              child: ChatEventPill(
                event: ChatEvent(kind: ChatEventKind.arrived, at: ChatFixtures.at(11, 27), label: 'Joseph arrived'),
                time: '11:27 AM',
              ),
            ),
          ),
          KeyedSubtree(
            key: const ValueKey('composer'),
            child: ChatComposer(controller: TextEditingController(), onAttach: () {}, onCamera: () {}, onSend: () {}),
          ),
          KeyedSubtree(key: const ValueKey('bar'), child: jobBar(bar(client: true, selected: 'them', lc: lifecycle('in_escrow')))),
        ]),
      ),
    );
    Size sizeOf(String key) => tester.getSize(find.byKey(ValueKey(key)));
    Finder labelled(String label) =>
        find.byWidgetPredicate((w) => w is Semantics && w.properties.label == label);

    expect(sizeOf('hello').height, 34, reason: 'a one-word reply is one line');
    // Capped at 288, and filled to within one glyph of it.
    expect(sizeOf('long').width, inInclusiveRange(ChatGeometry.textMaxWidth - 10, ChatGeometry.textMaxWidth));
    expect(sizeOf('photo').width, ChatGeometry.mediaWidth);
    expect(sizeOf('photo').height, ChatGeometry.mediaWidth * 3 / 4, reason: 'a 4:3 photo');
    expect(sizeOf('day').height, ChatGeometry.datePillHeight);
    expect(sizeOf('event').height, ChatGeometry.eventPillHeight);
    expect(sizeOf('composer').height, 6 + ChatGeometry.composerHeight + 8);

    final send = find.descendant(of: find.byKey(const ValueKey('composer')), matching: labelled('Send'));
    expect(tester.getSize(send), const Size.square(ChatGeometry.sendDiameter));
    final pill = find.descendant(of: find.byKey(const ValueKey('photo')), matching: find.byType(ChatMediaPill));
    expect(tester.getSize(pill).height, ChatGeometry.mediaPillHeight);
    final pillBox = tester.getRect(pill);
    final photoBox = tester.getRect(find.byKey(const ValueKey('photo')));
    expect(photoBox.right - pillBox.right, ChatGeometry.mediaPillInset);
    expect(photoBox.bottom - pillBox.bottom, ChatGeometry.mediaPillInset);

    // The job bar's button: drawn 34 tall, a 44 tall target.
    final action = find.descendant(of: find.byKey(const ValueKey('bar')), matching: labelled('Details'));
    expect(tester.getSize(action).height, ChatGeometry.minTouch);
    expect(
      tester.getSize(find.descendant(of: action, matching: find.byType(Container)).first).height,
      ChatGeometry.jobButtonHeight,
    );
  });

  for (final scene in scenes.entries) {
    final padded = !scene.key.startsWith('screen_') && !scene.key.startsWith('header') &&
        !scene.key.startsWith('composer') && !scene.key.startsWith('quick') &&
        !scene.key.startsWith('job_bar') && scene.key != 'offline_banner';

    testWidgets('${scene.key}: light and dark are the same component, re-toned', (tester) async {
      await prepare(tester);
      final boxes = <Brightness, List<String>>{};
      for (final b in Brightness.values) {
        await pumpShot(tester, frame(b, scene.value(), padded: padded));
        expect(tester.takeException(), isNull);
        boxes[b] = geometry(tester);
        await saveShot(tester, 'after/${b.name}/${scene.key}');
      }
      expect(boxes[Brightness.dark], boxes[Brightness.light],
          reason: 'only colour may differ between the themes');
    });

    testWidgets('${scene.key}: large system text grows instead of clipping', (tester) async {
      await prepare(tester);
      for (final scale in const [1.3, 2.0]) {
        await pumpShot(tester, frame(Brightness.light, scene.value(), textScale: scale, padded: padded));
        expect(tester.takeException(), isNull, reason: 'at ${scale}x');
        expect(clippedText(tester), isEmpty, reason: 'at ${scale}x');
        if (scale == 1.3) await saveShot(tester, 'after/text130/${scene.key}');
      }
    });
  }
}
