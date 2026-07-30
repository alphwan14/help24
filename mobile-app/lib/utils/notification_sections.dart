import 'package:flutter/foundation.dart';

import '../models/app_notification.dart';

/// One row in the notification centre: a single notification, or several that
/// say the same thing about the same subject.
///
/// WHY GROUPING IS PART OF THE MODEL AND NOT THE WIDGET
/// ----------------------------------------------------
/// Five applications on one job are five rows of near-identical text, and the
/// user has ONE decision to make about them: open the applicants list. Rendering
/// them separately is not neutral — it buries the four other things that
/// happened today under a wall of the same sentence, which is exactly how a
/// register stops being scannable and starts being ignored.
///
/// Grouping is deliberately CONSECUTIVE-ONLY. Collapsing every matching row
/// wherever it sits in the timeline would let a notification from last Tuesday
/// be swallowed into a group at the top of today, which silently rewrites
/// history. Adjacent rows are the only ones a reader would have seen together
/// anyway.
@immutable
class NotificationGroup {
  /// Newest first. Never empty; a group of one is the ordinary case.
  final List<AppNotification> items;

  const NotificationGroup(this.items);

  AppNotification get lead => items.first;
  int get length => items.length;
  bool get isGroup => items.length > 1;

  /// A group is unread if ANY member is. Reading four of five applications does
  /// not make the fifth read.
  bool get hasUnread => items.any((n) => !n.read);

  int get unreadCount => items.where((n) => !n.read).length;

  NotificationKind get kind => lead.kind;

  /// Stable across rebuilds so the list keeps element identity and does not
  /// re-animate rows that did not change.
  String get key => '${lead.groupKey}:${items.length}:${lead.id}';
}

/// A titled block of groups.
@immutable
class NotificationSection {
  final String title;
  final List<NotificationGroup> groups;

  /// Whether this is the pinned attention block rather than history. The two
  /// are rendered differently and one of them is allowed to be empty.
  final bool pinned;

  const NotificationSection({
    required this.title,
    required this.groups,
    this.pinned = false,
  });

  bool get isEmpty => groups.isEmpty;
}

/// Collapse runs of identical-subject notifications.
List<NotificationGroup> groupConsecutive(List<AppNotification> rows) {
  final groups = <NotificationGroup>[];
  var run = <AppNotification>[];
  for (final row in rows) {
    if (run.isEmpty || run.first.groupKey == row.groupKey) {
      run.add(row);
      continue;
    }
    groups.add(NotificationGroup(List.unmodifiable(run)));
    run = [row];
  }
  if (run.isNotEmpty) groups.add(NotificationGroup(List.unmodifiable(run)));
  return groups;
}

/// The date bucket a notification falls into, relative to [now].
///
/// Calendar days, not elapsed hours: something that happened at 11pm last night
/// is "Yesterday" at 1am, because that is what the reader means by it.
String dateBucketFor(DateTime at, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  final daysAgo = today.difference(day).inDays;
  if (daysAgo <= 0) return 'Today';
  if (daysAgo == 1) return 'Yesterday';
  if (daysAgo < 7) return 'This week';
  if (daysAgo < 30) return 'This month';
  return 'Earlier';
}

/// The whole register, as the sections the screen renders.
///
/// [attention] is the pinned block — unread, high-or-critical work — and
/// [timeline] is everything else in reverse-chronological order, bucketed by
/// day. A notification appears in exactly ONE of them: duplicating a row into
/// both would make the register look like it contained more than it does, and
/// make "mark all read" appear to do half a job.
///
/// [categoryFilter] narrows both blocks. Filtering to a category the user has
/// nothing in yields empty sections rather than a lie about the whole inbox.
List<NotificationSection> buildSections({
  required List<AppNotification> attention,
  required List<AppNotification> timeline,
  required DateTime now,
  NotificationCategory? categoryFilter,
}) {
  bool matches(AppNotification n) =>
      categoryFilter == null || n.kind.category == categoryFilter;

  final sections = <NotificationSection>[];

  final pinned = attention.where(matches).toList();
  if (pinned.isNotEmpty) {
    sections.add(NotificationSection(
      title: 'Needs your attention',
      groups: groupConsecutive(pinned),
      pinned: true,
    ));
  }

  // Bucketed in one pass over an already-sorted list, so the buckets come out
  // newest-first without a second sort.
  final buckets = <String, List<AppNotification>>{};
  final order = <String>[];
  for (final n in timeline) {
    if (!matches(n)) continue;
    final bucket = dateBucketFor(n.createdAt, now);
    final rows = buckets.putIfAbsent(bucket, () {
      order.add(bucket);
      return <AppNotification>[];
    });
    rows.add(n);
  }
  for (final bucket in order) {
    sections.add(NotificationSection(
      title: bucket,
      groups: groupConsecutive(buckets[bucket]!),
    ));
  }

  return sections;
}

/// The categories actually present, in the taxonomy's own order, so the filter
/// chips only ever offer a user something they have.
List<NotificationCategory> categoriesPresent(List<AppNotification> rows) {
  final present = <NotificationCategory>{for (final n in rows) n.kind.category};
  return [
    for (final category in NotificationCategory.values)
      if (present.contains(category)) category,
  ];
}
