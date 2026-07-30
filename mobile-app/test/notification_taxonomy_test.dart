import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/app_notification.dart';
import 'package:help24/utils/notification_sections.dart';

/// Regression suite: EVERY NOTIFICATION MEANS SOMETHING, GOES SOMEWHERE, AND
/// SITS WHERE IT BELONGS.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// The taxonomy lived in three files that were maintained separately and agreed
/// in none: the backend's canonical `NotificationType` union (22 types), the
/// tile's icon `switch` (14) and the tap router's `switch` (16). The arithmetic
/// was the bug — seven types, including every `promotion_*` and `review_received`,
/// rendered as an anonymous grey bell AND did nothing at all when tapped. A
/// provider told their campaign had been rejected could tap that row forever.
///
/// [NotificationKind] is now the one definition, and the register's ordering,
/// grouping and sectioning are pure functions over it.

/// The types `backend/src/notifications/notifications.service.ts` declares in
/// its canonical `NotificationType` union. If the backend adds one, this list
/// gets it and the test below says whether the client understood.
const _backendTypes = <String>[
  'provider_applied',
  'provider_selected',
  'payment_secured',
  'chat_message',
  'completion_requested',
  'job_approved',
  'payout_released',
  'dispute_opened',
  'dispute_resolved_release',
  'dispute_resolved_refund',
  'dispute_resolved_partial',
  'dispute_message',
  'dispute_evidence_requested',
  'dispute_evidence_uploaded',
  'escrow_released',
  'review_requested',
  'review_received',
  'job_cancelled',
  'promotion_payment_received',
  'promotion_live',
  'promotion_rejected',
  'promotion_completed',
];

AppNotification _n(
  String id, {
  String type = 'provider_applied',
  bool read = false,
  DateTime? at,
  Map<String, dynamic> data = const {},
}) =>
    AppNotification(
      id: id,
      type: type,
      title: 'Title $id',
      body: 'Body $id',
      data: data,
      read: read,
      createdAt: at ?? DateTime(2026, 7, 30, 9),
    );

void main() {
  final now = DateTime(2026, 7, 30, 18);

  group('the taxonomy is total over what the backend emits', () {
    test('every canonical backend type is understood', () {
      final unmapped = [
        for (final type in _backendTypes)
          if (identical(NotificationKind.of(type), NotificationKind.unknown)) type,
      ];
      expect(unmapped, isEmpty,
          reason: 'these render as an anonymous bell: $unmapped');
    });

    test('every understood type has a category and a priority', () {
      for (final kind in NotificationKind.all) {
        expect(kind.type, isNotEmpty);
        expect(kind.category, isNotNull);
        expect(kind.priority, isNotNull);
      }
    });

    test('a type this build has never seen still renders and still routes', () {
      // The forward-compatibility guarantee: it is safe to ship a backend
      // notification type before the client that understands it.
      final kind = NotificationKind.of('some_future_type');
      expect(kind, same(NotificationKind.unknown));
      expect(kind.icon, isNotNull);
      expect(kind.category, NotificationCategory.system);
    });

    test('no type is registered twice', () {
      final types = NotificationKind.all.map((k) => k.type).toList();
      expect(types.toSet().length, types.length);
    });
  });

  group('priority reflects what is actually at stake', () {
    test('money and disputes are critical', () {
      for (final type in [
        'payment_secured',
        'payout_released',
        'escrow_released',
        'dispute_opened',
        'dispute_evidence_requested',
        'dispute_resolved_release',
        'dispute_resolved_refund',
        'dispute_resolved_partial',
      ]) {
        expect(NotificationKind.of(type).priority, NotificationPriority.critical,
            reason: '$type involves real funds');
      }
    });

    test('being waited on is high', () {
      for (final type in [
        'provider_applied',
        'provider_selected',
        'completion_requested',
        'review_requested',
      ]) {
        expect(NotificationKind.of(type).priority, NotificationPriority.high,
            reason: '$type is somebody waiting on this user');
      }
    });

    test('bookkeeping sits at the bottom', () {
      for (final type in [
        'badge_earned',
        'profile_updated',
        'promotion_completed',
        'maintenance',
      ]) {
        expect(NotificationKind.of(type).priority, NotificationPriority.low,
            reason: '$type is true and unremarkable');
      }
    });

    test('a dispute outranks a badge', () {
      expect(
        NotificationKind.of('dispute_opened').priority.weight,
        lessThan(NotificationKind.of('badge_earned').priority.weight),
      );
    });

    test('only critical and high are ever pinned', () {
      expect(NotificationPriority.critical.isPinnable, isTrue);
      expect(NotificationPriority.high.isPinnable, isTrue);
      expect(NotificationPriority.normal.isPinnable, isFalse);
      expect(NotificationPriority.low.isPinnable, isFalse);
    });
  });

  group('grouping collapses repetition, never history', () {
    test('same kind, same subject collapses into one row', () {
      final rows = [
        _n('1', data: {'post_id': 'p1'}),
        _n('2', data: {'post_id': 'p1'}),
        _n('3', data: {'post_id': 'p1'}),
      ];
      final groups = groupConsecutive(rows);

      expect(groups.length, 1);
      expect(groups.first.length, 3);
      expect(groups.first.isGroup, isTrue);
    });

    test('same kind, DIFFERENT subject stays separate', () {
      // Three applications on three jobs are three decisions, not one.
      final groups = groupConsecutive([
        _n('1', data: {'post_id': 'p1'}),
        _n('2', data: {'post_id': 'p2'}),
      ]);
      expect(groups.length, 2);
    });

    test('different kinds on the same subject stay separate', () {
      final groups = groupConsecutive([
        _n('1', type: 'provider_applied', data: {'post_id': 'p1'}),
        _n('2', type: 'payment_secured', data: {'post_id': 'p1'}),
      ]);
      expect(groups.length, 2);
    });

    test('grouping is consecutive-only — it cannot rewrite the timeline', () {
      // Collapsing matches wherever they sit would let last Tuesday's row be
      // swallowed into a group at the top of today.
      final groups = groupConsecutive([
        _n('1', data: {'post_id': 'p1'}),
        _n('2', data: {'post_id': 'p2'}),
        _n('3', data: {'post_id': 'p1'}),
      ]);
      expect(groups.map((g) => g.length), [1, 1, 1]);
    });

    test('a group is unread while ANY member is', () {
      final group = groupConsecutive([
        _n('1', read: true, data: {'post_id': 'p1'}),
        _n('2', data: {'post_id': 'p1'}),
      ]).single;

      expect(group.hasUnread, isTrue);
      expect(group.unreadCount, 1);
    });
  });

  group('date buckets follow calendar days, not elapsed hours', () {
    test('11pm last night is Yesterday at 1am', () {
      expect(
        dateBucketFor(DateTime(2026, 7, 29, 23), DateTime(2026, 7, 30, 1)),
        'Yesterday',
      );
    });

    test('this morning is Today', () {
      expect(dateBucketFor(DateTime(2026, 7, 30, 8), now), 'Today');
    });

    test('four days ago is This week', () {
      expect(dateBucketFor(DateTime(2026, 7, 26), now), 'This week');
    });

    test('two months ago is Earlier', () {
      expect(dateBucketFor(DateTime(2026, 5, 20), now), 'Earlier');
    });
  });

  group('sections: importance surfaces, recency orders', () {
    test('unread critical work is pinned above the timeline', () {
      final sections = buildSections(
        attention: [_n('d', type: 'dispute_opened', data: {'post_id': 'p1'})],
        timeline: [_n('r', type: 'review_received', read: true)],
        now: now,
      );

      expect(sections.first.title, 'Needs your attention');
      expect(sections.first.pinned, isTrue);
      expect(sections.length, 2);
    });

    test('a notification appears in exactly one block', () {
      // Duplicating a row into both would make the register look like it held
      // more than it does, and make "mark all read" look like it half-worked.
      final pinned = _n('d', type: 'dispute_opened');
      final sections = buildSections(
        attention: [pinned],
        timeline: [_n('r', type: 'review_received', read: true)],
        now: now,
      );
      final ids = [
        for (final s in sections)
          for (final g in s.groups)
            for (final n in g.items) n.id,
      ];
      expect(ids.where((id) => id == 'd').length, 1);
    });

    test('with nothing urgent there is no pinned block at all', () {
      final sections = buildSections(
        attention: const [],
        timeline: [_n('r', type: 'review_received', read: true)],
        now: now,
      );
      expect(sections.any((s) => s.pinned), isFalse);
    });

    test('the timeline stays reverse-chronological across buckets', () {
      final sections = buildSections(
        attention: const [],
        timeline: [
          _n('today', at: DateTime(2026, 7, 30, 8)),
          _n('yesterday', at: DateTime(2026, 7, 29, 8)),
          _n('old', at: DateTime(2026, 5, 1)),
        ],
        now: now,
      );
      expect(sections.map((s) => s.title), ['Today', 'Yesterday', 'Earlier']);
    });

    test('a category filter narrows both blocks', () {
      final sections = buildSections(
        attention: [_n('d', type: 'dispute_opened')],
        timeline: [_n('p', type: 'promotion_live', read: true)],
        now: now,
        categoryFilter: NotificationCategory.disputes,
      );

      final types = [
        for (final s in sections)
          for (final g in s.groups)
            for (final n in g.items) n.type,
      ];
      expect(types, ['dispute_opened']);
    });

    test('a filter with nothing behind it yields no sections, not a lie', () {
      final sections = buildSections(
        attention: const [],
        timeline: [_n('p', type: 'promotion_live', read: true)],
        now: now,
        categoryFilter: NotificationCategory.disputes,
      );
      expect(sections, isEmpty);
    });
  });

  group('filter chips only offer what the user has', () {
    test('categories present are drawn from the rows', () {
      final categories = categoriesPresent([
        _n('1', type: 'provider_applied'),
        _n('2', type: 'payment_secured'),
        _n('3', type: 'provider_applied'),
      ]);

      expect(categories, [
        NotificationCategory.applications,
        NotificationCategory.payments,
      ]);
    });

    test('an empty register offers no chips', () {
      expect(categoriesPresent(const []), isEmpty);
    });
  });

  group('a notification knows what it is about', () {
    test('it reads its subject out of the payload', () {
      final n = _n('1', data: {'post_id': 'p1', 'chat_id': 'c1'});
      expect(n.postId, 'p1');
      expect(n.chatId, 'c1');
    });

    test('an empty payload value is absent, not an empty string', () {
      // A blank post_id would otherwise route the user to a job that is not
      // there, which reads as a broken link rather than a missing one.
      final n = _n('1', data: {'post_id': '  '});
      expect(n.postId, isNull);
    });

    test('the group key is kind plus subject', () {
      final a = _n('1', type: 'provider_applied', data: {'post_id': 'p1'});
      final b = _n('2', type: 'provider_applied', data: {'post_id': 'p1'});
      final c = _n('3', type: 'provider_applied', data: {'post_id': 'p2'});

      expect(a.groupKey, b.groupKey);
      expect(a.groupKey, isNot(c.groupKey));
    });

    test('a notification with no subject groups only with itself', () {
      // Falls back to its own id, so two unrelated system notices never
      // collapse into "2 system notices" on the strength of both lacking a
      // subject.
      final a = _n('1', type: 'maintenance');
      final b = _n('2', type: 'maintenance');
      expect(a.groupKey, isNot(b.groupKey));
    });
  });
}
