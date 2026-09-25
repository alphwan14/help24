import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A PUBLIC PROFILE MAY PRINT COUNTS FREELY AND PERCENTAGES ONLY WITH A SAMPLE.
///
/// WHAT WENT WRONG
/// ---------------
/// The trust block rendered `44% Dispute Rate` in the same size and weight as
/// `Jobs Completed`. The figure was arithmetically correct and
/// informationally worthless — it was 4 of 9 — and it sat on a stranger's
/// public profile as if it were a settled fact about how they work.
///
/// The failure is symmetric, which is what makes it a rule rather than a
/// judgement call:
///
///   * 1 dispute out of 2 jobs prints **50% Dispute Rate**, which will follow
///     that provider until they complete enough work to dilute it — on a
///     marketplace that currently has no provider with that much work.
///   * 1 job out of 1 prints **100% Completion Rate**, a perfect record earned
///     by one transaction.
///
/// Both are a ratio dressed as a rate, with the denominator that would let
/// anyone judge it left off.
///
/// WHY THIS IS A SOURCE TEST
/// -------------------------
/// The block self-loads from `ReputationService` over the network, so rendering
/// it in a widget test means standing up a fake service and a fake HTTP layer
/// to assert on a formatting rule. The rule lives in two lines; this pins those
/// two lines, and pins the reasoning next to them so the next person to add a
/// metric knows which side of it their metric falls on.
void main() {
  final source =
      File('lib/widgets/reputation_widgets.dart').readAsStringSync();

  group('percentages are gated on sample size', () {
    test('there is a stated minimum, and it is a named constant', () {
      expect(
        source,
        contains('static const int _percentageMinimumSample'),
        reason: 'a threshold spelled inline at the call site is a threshold '
            'nobody can find or argue with',
      );
    });

    test('completion rate is inside the gate', () {
      final gate = source.indexOf('if (_percentagesAreMeaningful(rep))');
      expect(gate, greaterThan(-1), reason: 'the gate must exist');
      // Everything the gate covers sits between it and the next sibling.
      final gated = source.substring(gate, gate + 900);
      expect(gated, contains("'Completion Rate'"));
    });

    test('dispute rate is inside the gate AND suppressed at zero', () {
      final gate = source.indexOf('if (_percentagesAreMeaningful(rep))');
      final gated = source.substring(gate, gate + 900);
      expect(gated, contains("'Dispute Rate'"));
      expect(
        gated,
        contains('rep.disputePercent > 0'),
        reason: '"0% Dispute Rate" is a claim earned by not having been '
            'complained about yet, and it displaced a real metric',
      );
    });
  });

  group('counts are not gated', () {
    test('jobs completed is printed at any volume', () {
      // The count is the honest version of the same information, and it is what
      // lets a reader judge every percentage beside it — so it must sit BEFORE
      // the gate, not inside it.
      final gate = source.indexOf('if (_percentagesAreMeaningful(rep))');
      final jobsCompleted = source.indexOf("'Jobs Completed'");
      expect(jobsCompleted, greaterThan(-1));
      expect(jobsCompleted, lessThan(gate),
          reason: 'Jobs Completed must sit OUTSIDE the sample gate');
    });

    test('an OPEN dispute is shown at any volume', () {
      // The one signal that must never be withheld: it is a fact about right
      // now, not a rate, and it is the thing a client would actually act on.
      final gate = source.indexOf('if (_percentagesAreMeaningful(rep))');
      final openDisputes = source.indexOf("'Open Disputes'");
      expect(openDisputes, greaterThan(-1));
      final guard = source.lastIndexOf('if (rep.openDisputes > 0)', openDisputes);
      expect(guard, greaterThan(gate),
          reason: 'Open Disputes must sit OUTSIDE the sample gate');
    });

    test('zero open disputes is not printed', () {
      expect(source, contains('if (rep.openDisputes > 0)'),
          reason: '"0 Open Disputes" is not news, and printing it beside a '
              'dispute RATE was two metrics for one idea');
    });
  });
}
