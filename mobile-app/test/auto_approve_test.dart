import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/job_lifecycle.dart';
import 'package:help24/utils/time_utils.dart';

/// The review window (backend migration 134): a pending completion approves
/// itself at `auto_approve_at`, and the approve screen says when.
void main() {
  group('LifecycleCompletion reads the review window', () {
    test('a pending completion carries its deadline', () {
      final c = LifecycleCompletion.fromJson({
        'id': 'c1',
        'status': 'pending_approval',
        'created_at': '2026-11-04T10:00:00Z',
        'auto_approve_at': '2026-11-06T10:00:00Z',
      });
      expect(c.autoApproveAt, DateTime.utc(2026, 11, 6, 10));
      expect(c.approvedAutomatically, isFalse);
    });

    test('a completion from before the window has none, and waits for the client', () {
      final c = LifecycleCompletion.fromJson({'id': 'c1', 'status': 'pending_approval'});
      expect(c.autoApproveAt, isNull);
    });

    test('an approval made by the system is told apart from the client\'s', () {
      final c = LifecycleCompletion.fromJson({'id': 'c1', 'status': 'approved', 'approved_by': 'system'});
      expect(c.approvedAutomatically, isTrue);
      expect(
        LifecycleCompletion.fromJson({'id': 'c1', 'status': 'approved', 'approved_by': 'client'}).approvedAutomatically,
        isFalse,
      );
    });
  });

  testWidgets('a deadline reads as today / tomorrow / a named day, never "Yesterday"', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(alwaysUse24HourFormat: true),
      child: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }),
    ));

    final now = DateTime.now();
    final todayLater = DateTime(now.year, now.month, now.day, 23, 59);
    final tomorrow = DateTime(now.year, now.month, now.day + 1, 14, 5);
    final inFourDays = DateTime(now.year, now.month, now.day + 4, 9, 0);

    expect(formatUpcomingStamp(ctx, todayLater), 'today at 23:59');
    expect(formatUpcomingStamp(ctx, tomorrow), 'tomorrow at 14:05');
    expect(formatUpcomingStamp(ctx, inFourDays), matches(RegExp(r'^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) \d{1,2} [A-Z][a-z]{2} at 09:00$')));
  });
}
