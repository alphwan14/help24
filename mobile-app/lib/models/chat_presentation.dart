import 'package:flutter/widgets.dart';

import '../services/outbox_delivery.dart' show OutboxIds;
import '../services/outbox_store.dart' show OutboxStatus;
import '../theme/tokens.dart' show ChatGeometry;
import '../utils/time_utils.dart';
import 'post_model.dart';

// =============================================================================
// THE CHAT'S PRESENTATION RULES, AS PURE FUNCTIONS.
//
// Everything a bubble needs to decide that is not a pixel lives here — which
// tick it shows, whether it joins the bubble above, what its day is called,
// what its file line says — so every rule is checkable without a widget tree
// and the thread cannot render one rule two ways.
// =============================================================================

// ── Sending state ────────────────────────────────────────────────────────────

/// What an OUTGOING message shows beside its time.
///
///   queued    — in the outbox: offline, or not yet accepted by the server.
///               A clock, and the bubble at 85%.
///   sent      — the server has the row. One muted tick.
///   delivered — the recipient's phone acknowledged it. Two muted ticks.
///   read      — the recipient opened it. Two ticks in `statusRead`.
///   failed    — the outbox gave up. An alert, the bubble at 70%, and
///               "Not sent. Tap to retry".
enum ChatSendState { queued, sent, delivered, read, failed }

/// The single mapping from a message's stored fields to [ChatSendState].
///
/// A message still in the outbox is `queued` whether a request is open for it
/// or not — the user cannot act on the difference, and an upload in flight
/// shows its own progress ring. Read outranks delivered: a late delivered
/// receipt can never pull a read message back to grey ticks.
ChatSendState chatSendStateOf(Message m) {
  if (OutboxIds.isPending(m.id) || OutboxStatus.isUnsent(m.status)) {
    return m.status == OutboxStatus.failed
        ? ChatSendState.failed
        : ChatSendState.queued;
  }
  if (m.status == 'seen' || m.seenAt != null) return ChatSendState.read;
  if (m.deliveredAt != null) return ChatSendState.delivered;
  return ChatSendState.sent;
}

// ── Runs ─────────────────────────────────────────────────────────────────────

/// Whether [next] continues the run [previous] belongs to: the same sender,
/// within [ChatGeometry.groupWindow] of it, on the same local day.
bool continuesRun(Message previous, Message next) {
  if (previous.isMe != next.isMe) return false;
  if (!isSameLocalDay(previous.timestamp, next.timestamp)) return false;
  final gap = next.timestamp.difference(previous.timestamp).abs();
  return gap < ChatGeometry.groupWindow;
}

/// Where a bubble sits in its run — which corners meet a neighbour.
@immutable
class RunPosition {
  const RunPosition({required this.first, required this.last});

  /// No bubble from the same run above it.
  final bool first;

  /// No bubble from the same run below it.
  final bool last;

  bool get alone => first && last;

  @override
  bool operator ==(Object other) =>
      other is RunPosition && other.first == first && other.last == last;

  @override
  int get hashCode => Object.hash(first, last);

  @override
  String toString() => 'RunPosition(first: $first, last: $last)';
}

// ── Thread entries ───────────────────────────────────────────────────────────

/// One row of the rendered thread.
sealed class ChatThreadEntry {
  const ChatThreadEntry();

  /// Stable identity, for element reuse and scroll-to-message.
  String get key;
}

class ChatDayEntry extends ChatThreadEntry {
  const ChatDayEntry(this.day);

  /// Local midnight of the day.
  final DateTime day;

  @override
  String get key => 'd_${day.year}-${day.month}-${day.day}';
}

class ChatMessageEntry extends ChatThreadEntry {
  const ChatMessageEntry(this.message, this.position);

  final Message message;
  final RunPosition position;

  @override
  String get key => 'm_${message.id}';
}

class ChatEventEntry extends ChatThreadEntry {
  const ChatEventEntry(this.event);

  final ChatEvent event;

  @override
  String get key => event.key;
}

class ChatOfferEntry extends ChatThreadEntry {
  const ChatOfferEntry(this.offer);

  final ChatThreadOffer offer;

  @override
  String get key => 'o_${offer.id}';
}

enum ChatOfferStatus { pending, accepted, notSelected }

/// An offer made on this chat's job, shown where it was made in the thread.
///
/// It is the post's APPLICATION between these two people — a real row, with
/// its own time, price and message — not a chat message: the app has never
/// posted offers into the thread. Only the pair's own application is shown,
/// so nobody sees an offer they were not party to.
@immutable
class ChatThreadOffer {
  const ChatThreadOffer({
    required this.id,
    required this.mine,
    required this.price,
    required this.at,
    required this.status,
    this.message = '',
    this.acceptedBy,
  });

  final String id;

  /// The viewer made it.
  final bool mine;
  final double price;
  final DateTime at;
  final String message;
  final ChatOfferStatus status;

  /// Who accepted it — "Amina", or "you".
  final String? acceptedBy;
}

/// The kinds of job event a thread shows as a centred pill.
enum ChatEventKind { paidHeld, arrived, completionRequested, completed, released, disputeOpened }

/// A job event in the thread: either a message the app already posts (the
/// arrival notice, a journey that ended "Arrived") or a stage the server
/// recorded for this job. Never invented — see [chatEventFromMessage] and the
/// job-bar notes in `chat_job_stage.dart`.
@immutable
class ChatEvent {
  const ChatEvent({
    required this.kind,
    required this.at,
    required this.label,
    this.message,
    this.sourceKey,
  });

  final ChatEventKind kind;
  final DateTime at;
  final String label;

  /// The message behind it, when it is one (long-press still works on it).
  final Message? message;

  /// Identity for an event that is not a message.
  final String? sourceKey;

  String get key => message != null ? 'm_${message!.id}' : 'e_${sourceKey ?? '${kind.name}_${at.microsecondsSinceEpoch}'}';
}

/// The one-tap heads-up the app sends when someone arrives ("Notify" after
/// "I've arrived"). Sent and recognised from this one constant, so the
/// notice renders as an event pill and not as a sentence someone typed.
const String kArrivalNoticeText = "🔔 I've arrived at the location.";

/// The thread's arrival events, from the messages the app already sends:
/// the arrival notice, and a journey card that ended "Arrived". Anything else
/// is an ordinary bubble.
ChatEvent? chatEventFromMessage(Message m, {required String partnerName}) {
  if (m.deletedForEveryone) return null;
  final who = m.isMe ? 'You' : (partnerName.trim().isEmpty ? 'They' : partnerName.trim());
  if (m.type == 'text' && m.text.trim() == kArrivalNoticeText) {
    return ChatEvent(kind: ChatEventKind.arrived, at: m.timestamp, label: '$who arrived', message: m);
  }
  if (m.isJourneyArrived) {
    return ChatEvent(
      kind: ChatEventKind.arrived,
      at: m.liveUntil ?? m.timestamp,
      label: '$who arrived',
      message: m,
    );
  }
  return null;
}

/// THE THREAD AS IT IS DRAWN: a day pill whenever the local day changes,
/// messages with their run position, and job events as pills in time order.
///
/// An event, a day change or a change of sender ends a run; so does a gap of
/// [ChatGeometry.groupWindow] or more.
List<ChatThreadEntry> buildChatThread(
  List<Message> messages, {
  List<ChatEvent> extraEvents = const [],
  List<ChatThreadOffer> offers = const [],
  String partnerName = '',
}) {
  // Messages first, each either a bubble or (arrival) an event.
  final rows = <({DateTime at, Message? message, ChatEvent? event, ChatThreadOffer? offer})>[];
  for (final m in messages) {
    final event = chatEventFromMessage(m, partnerName: partnerName);
    rows.add((at: event?.at ?? m.timestamp, message: event == null ? m : null, event: event, offer: null));
  }
  for (final e in extraEvents) {
    rows.add((at: e.at, message: null, event: e, offer: null));
  }
  for (final o in offers) {
    rows.add((at: o.at, message: null, event: null, offer: o));
  }
  // Stable by time: messages arrive already ordered, and an event placed at
  // the same instant as a message goes after it.
  final indexed = rows.indexed.toList()
    ..sort((a, b) {
      final c = a.$2.at.compareTo(b.$2.at);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
  final ordered = [for (final r in indexed) r.$2];

  final entries = <ChatThreadEntry>[];
  DateTime? lastDay;
  for (var i = 0; i < ordered.length; i++) {
    final row = ordered[i];
    final day = localDay(row.at);
    if (lastDay == null || day != lastDay) {
      entries.add(ChatDayEntry(day));
      lastDay = day;
    }
    final m = row.message;
    if (m == null) {
      entries.add(row.offer != null ? ChatOfferEntry(row.offer!) : ChatEventEntry(row.event!));
      continue;
    }
    final prev = i > 0 ? ordered[i - 1].message : null;
    final next = i < ordered.length - 1 ? ordered[i + 1].message : null;
    entries.add(ChatMessageEntry(
      m,
      RunPosition(
        first: prev == null || !continuesRun(prev, m),
        last: next == null || !continuesRun(m, next),
      ),
    ));
  }
  return entries;
}

// ── Time ─────────────────────────────────────────────────────────────────────

const List<String> _weekdaysLong = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
];
const List<String> _monthsShort = [
  '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// The day pill: "Today", "Yesterday", the weekday within the last week
/// ("Tuesday"), then "25 Sep" — with the year when it is not this year.
String chatDayLabel(DateTime t, {DateTime? now}) {
  final day = localDay(t);
  final today = localDay(now ?? DateTime.now());
  // Calendar days, not 24-hour spans: counted on UTC dates so a daylight
  // saving change cannot make "yesterday" 23 hours long.
  final days = DateTime.utc(today.year, today.month, today.day)
      .difference(DateTime.utc(day.year, day.month, day.day))
      .inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days > 1 && days < 7) return _weekdaysLong[day.weekday - 1];
  final base = '${day.day} ${_monthsShort[day.month]}';
  return day.year == today.year ? base : '$base ${day.year}';
}

/// The time inside a bubble: the clock only ("1:15 PM", or "13:15" on a
/// 24-hour phone). The date is the day pill's job.
String chatBubbleTime(BuildContext context, DateTime t) => formatClockTime(context, t);

/// The full stamp for message info: "Tuesday 25 Sep 2026 at 1:15 PM" — the
/// form a dispute needs, with nothing left to infer.
String chatInfoStamp(DateTime t, {required bool use24Hour}) {
  final l = t.toLocal();
  final minute = l.minute.toString().padLeft(2, '0');
  final clock = use24Hour
      ? '${l.hour.toString().padLeft(2, '0')}:$minute'
      : '${l.hour % 12 == 0 ? 12 : l.hour % 12}:$minute ${l.hour < 12 ? 'AM' : 'PM'}';
  return '${_weekdaysLong[l.weekday - 1]} ${l.day} ${_monthsShort[l.month]} ${l.year} at $clock';
}

// ── Files ────────────────────────────────────────────────────────────────────

enum ChatFileKind { pdf, word, other }

ChatFileKind chatFileKindOf(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'pdf' => ChatFileKind.pdf,
    'doc' || 'docx' => ChatFileKind.word,
    _ => ChatFileKind.other,
  };
}

/// The short type label on the file line and the thumbnail strip.
String chatFileTypeLabel(String name) {
  switch (chatFileKindOf(name)) {
    case ChatFileKind.pdf:
      return 'PDF';
    case ChatFileKind.word:
      return 'DOC';
    case ChatFileKind.other:
      final dot = name.lastIndexOf('.');
      final ext = dot < 0 ? '' : name.substring(dot + 1).toUpperCase();
      return ext.isEmpty || ext.length > 4 ? 'FILE' : ext;
  }
}

/// "148 KB", "1.2 MB", "820 B".
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  return '${mb < 10 ? mb.toStringAsFixed(1) : mb.round()} MB';
}

/// "PDF · 2 pages · 148 KB". Pages and size are left out when they are not
/// known — nothing is downloaded just to count them.
String chatFileMetaLine(String name, {int? pages, int? bytes}) => [
      chatFileTypeLabel(name),
      if (pages != null && pages > 0) pages == 1 ? '1 page' : '$pages pages',
      if (bytes != null && bytes > 0) formatFileSize(bytes),
    ].join(' · ');

// ── Who the other person is ──────────────────────────────────────────────────

enum ChatPartnerRole { provider, customer, unknown }

/// Whether the person in this chat is the provider or the customer — read off
/// the chat's post: on a request the author is the customer and whoever came
/// to it the provider; on an offer it is the other way round. Without a post,
/// a profession or completed jobs make them a provider. Otherwise unknown.
ChatPartnerRole chatPartnerRoleOf({
  required String viewerId,
  required String partnerId,
  String? postAuthorId,
  bool postIsOffer = false,
  bool partnerHasProfession = false,
  int partnerCompletedJobs = 0,
}) {
  final author = (postAuthorId ?? '').trim();
  if (author.isNotEmpty) {
    if (partnerId == author) {
      return postIsOffer ? ChatPartnerRole.provider : ChatPartnerRole.customer;
    }
    if (viewerId == author) {
      return postIsOffer ? ChatPartnerRole.customer : ChatPartnerRole.provider;
    }
  }
  if (partnerHasProfession || partnerCompletedJobs > 0) return ChatPartnerRole.provider;
  return ChatPartnerRole.unknown;
}

/// The header's second line from the fields that exist: "Plumber · ★ 4.8 ·
/// 34 jobs", "Customer · Bamburi, Mombasa". Null when there is nothing to say
/// — the caller falls back to presence ("last seen…").
String? chatPartnerLine({
  required ChatPartnerRole role,
  String? professionLabel,
  double? rating,
  int completedJobs = 0,
  String? area,
}) {
  switch (role) {
    case ChatPartnerRole.customer:
      final a = (area ?? '').trim();
      return a.isEmpty ? null : 'Customer · $a';
    case ChatPartnerRole.provider:
      final label = (professionLabel ?? '').trim();
      final facts = [
        if (rating != null && rating > 0) '★ ${rating.toStringAsFixed(1)}',
        if (completedJobs > 0) completedJobs == 1 ? '1 job' : '$completedJobs jobs',
      ];
      if (label.isEmpty && facts.isEmpty) return null;
      return [label.isEmpty ? 'Provider' : label, ...facts].join(' · ');
    case ChatPartnerRole.unknown:
      return null;
  }
}
