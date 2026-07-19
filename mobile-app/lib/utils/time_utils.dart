import 'package:flutter/widgets.dart';

// =============================================================================
// Help24 canonical time handling
// =============================================================================
// ONE rule, applied everywhere:
//
//   STORE + TRANSPORT in UTC   →   PRESENT in the device's local zone.
//
// Nothing in this file (or anywhere in the app) may hardcode a timezone or an
// offset. The device is the source of truth for both the zone and the
// 12h/24h clock preference.
//
// Why this file exists — two real bugs it eliminates:
//
// 1. PARSE. `DateTime.parse` only marks its result UTC when the string carries
//    a designator (trailing `Z` or `±hh:mm`). PostgREST returns
//    "2026-07-19T01:11:00+00:00" (designator → UTC-flagged, correct), but
//    Realtime/WAL payloads commonly deliver "2026-07-19 01:11:00" with NO
//    designator. Dart then flags that value *local*, so the same row arriving
//    over the socket is a different instant than the one fetched over REST —
//    off by exactly the device's UTC offset. Route every server timestamp
//    through [parseServerTime] and both paths agree.
//
// 2. PRESENT. A UTC-flagged DateTime's `.hour` is the UTC hour. Call sites that
//    formatted `t.hour` directly rendered UTC wall-clock — 3 h behind in EAT —
//    while sites that called `.toLocal()` first rendered correctly. That split
//    is what made timestamps look inconsistent across the app. Route every
//    displayed timestamp through the formatters below and there is exactly one
//    behaviour.
// =============================================================================

/// Parses a server timestamp into a **UTC** [DateTime], regardless of whether
/// the wire format carried a timezone designator.
///
/// Accepts `String`, `DateTime`, or null. Returns null for null/blank/garbage
/// so callers can decide their own fallback rather than silently getting "now".
DateTime? parseServerTimeOrNull(Object? raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw.toUtc();

  final s = raw.toString().trim();
  if (s.isEmpty) return null;

  final parsed = DateTime.tryParse(s);
  if (parsed == null) return null;

  // Designator present (Z or ±hh:mm) → Dart already resolved it to a true UTC
  // instant. Nothing further to do; converting again would be a double shift.
  if (parsed.isUtc) return parsed;

  // No designator. Postgres `timestamptz` always hands out UTC instants, so the
  // parsed wall-clock components ARE the UTC values — Dart just mislabelled
  // them local. Reinterpret (do NOT .toUtc(), which would subtract the device
  // offset a second time and move the instant).
  return DateTime.utc(
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
    parsed.second,
    parsed.millisecond,
    parsed.microsecond,
  );
}

/// [parseServerTimeOrNull] with a fallback for non-nullable call sites.
DateTime parseServerTime(Object? raw, {DateTime? fallback}) =>
    parseServerTimeOrNull(raw) ?? fallback ?? DateTime.now().toUtc();

/// Serialises a timestamp for the wire as an unambiguous UTC ISO-8601 string
/// (always ends in `Z`). Use for every client-written timestamp so a naive
/// local string is never handed to a `timestamptz` column.
String toServerTime(DateTime t) => t.toUtc().toIso8601String();

/// True when the device is set to a 24-hour clock. Reads the platform setting —
/// never an app preference, never a guess.
bool uses24HourClock(BuildContext context) =>
    MediaQuery.of(context).alwaysUse24HourFormat;

/// Clock portion in the device's local zone and clock convention:
/// `16:35` on a 24-hour device, `4:35 PM` on a 12-hour device.
String formatClockTime(BuildContext context, DateTime t) {
  final l = t.toLocal();
  final minute = l.minute.toString().padLeft(2, '0');
  if (uses24HourClock(context)) {
    return '${l.hour.toString().padLeft(2, '0')}:$minute';
  }
  final hour12 = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '$hour12:$minute ${l.hour < 12 ? 'AM' : 'PM'}';
}

const List<String> _weekdays = [
  'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
];
const List<String> _months = [
  '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Calendar day of [t] in the **local** zone — the unit day-grouping and
/// "Today/Yesterday" comparisons must use. Comparing UTC components against a
/// local "today" mislabels messages either side of local midnight.
DateTime localDay(DateTime t) {
  final l = t.toLocal();
  return DateTime(l.year, l.month, l.day);
}

/// True when both instants fall on the same local calendar day.
bool isSameLocalDay(DateTime a, DateTime b) => localDay(a) == localDay(b);

/// Message-bubble / conversation stamp, local zone + device clock convention:
/// today → `16:35`, yesterday → `Yesterday 16:35`, this week → `Mon 16:35`,
/// older → `Jul 19, 16:35`.
String formatMessageStamp(BuildContext context, DateTime t) {
  final clock = formatClockTime(context, t);
  final day = localDay(t);
  final today = localDay(DateTime.now());

  if (day == today) return clock;
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday $clock';

  final local = t.toLocal();
  if (today.difference(day).inDays < 7) {
    return '${_weekdays[local.weekday - 1]} $clock';
  }
  return '${_months[local.month]} ${local.day}, $clock';
}

/// Date-separator label for a chat thread: `Today` / `Yesterday` /
/// `Mon, Jul 19` — all resolved against local calendar days.
String formatDateSeparator(DateTime t) {
  final day = localDay(t);
  final today = localDay(DateTime.now());
  if (day == today) return 'Today';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
  final local = t.toLocal();
  if (today.difference(day).inDays < 7) return _weekdays[local.weekday - 1];
  return '${_months[local.month]} ${local.day}';
}

/// Relative age ("2h ago", "Yesterday"). Instant-based, so it is correct for
/// any correctly-parsed timestamp regardless of zone flags.
String formatRelativeTime(DateTime dateTime) {
  final diff = DateTime.now().difference(dateTime.toLocal());

  if (diff.isNegative) return 'Just now'; // clock skew — never show "in 3h"
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays == 1) return 'Yesterday';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w ago';
  if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}mo ago';
  return '${(diff.inDays / 365).floor()}y ago';
}
