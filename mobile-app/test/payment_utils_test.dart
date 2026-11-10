import 'package:flutter_test/flutter_test.dart';
import 'package:help24/utils/payment_utils.dart';

/// THE GOLDEN TABLE. backend/src/mpesa/fee.spec.ts holds the same rows: the
/// backend charges the fee, this app shows it first, and the two must agree
/// to the shilling. [job, fee] in whole KES.
const List<List<int>> golden = [
  [100, 30], // floor
  [300, 30],
  [599, 30],
  [600, 30], // 5% meets the floor
  [610, 31], // 30.5 rounds up
  [1000, 50],
  [1010, 51], // 50.5 rounds up
  [1234, 62], // 61.7
  [2500, 125],
  [5000, 250],
  [10000, 500],
  [19990, 1000], // 999.5 rounds up to the cap
  [20000, 1000], // 5% meets the cap
  [50000, 1000], // capped
  [150000, 1000],
];

void main() {
  group('payment protection fee: 5% of the job, minimum KES 30, maximum KES 1,000', () {
    for (final row in golden) {
      test('KES ${row[0]} pays a fee of KES ${row[1]}', () {
        expect(calculatePlatformFee(row[0].toDouble()), row[1].toDouble());
        expect(calculateTotal(row[0].toDouble()), (row[0] + row[1]).toDouble());
      });
    }

    test('a dearer job never costs less in total (no cliff at any price)', () {
      var last = 0.0;
      int? firstCliff;
      for (var job = 100; job <= 60000 && firstCliff == null; job++) {
        final total = calculateTotal(job.toDouble());
        if (total <= last) firstCliff = job;
        last = total;
      }
      expect(firstCliff, isNull);
    });

    test('nothing to pay, no fee', () {
      expect(calculatePlatformFee(0), 0);
    });

    test('the explanation states the rule the code applies, in plain copy', () {
      expect(feeRuleText, contains('$feeRatePercent%'));
      expect(feeRuleText, contains('KES $feeMinKes'));
      expect(feeRuleText, contains('KES 1,000'));
      expect(feeMaxKes, 1000); // the text spells the cap out with a comma
      expect(feeRuleText.contains('—'), isFalse); // no em dash
    });
  });
}
