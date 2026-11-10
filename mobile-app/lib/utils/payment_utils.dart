// Help24's payment protection fee: 5% of the job, minimum KES 30, maximum
// KES 1,000, paid by the customer on top of the job. The provider keeps 100%.
//
// MIRRORS backend/src/mpesa/fee.ts, which charges it. This file only shows
// it, before the customer pays, so the two must agree to the shilling or the
// M-Pesa prompt contradicts the screen. test/payment_utils_test.dart and
// backend/src/mpesa/fee.spec.ts pin the same golden table.
const int feeRatePercent = 5;
const int feeMinKes = 30;
const int feeMaxKes = 1000;

/// The rule in one line, for the fee's explanation on the payment screen.
const String feeRuleText =
    '$feeRatePercent% of the service cost, minimum KES $feeMinKes, '
    'never more than KES 1,000. Your money is held until you approve the work.';

/// Returns the payment protection fee in KES for the given [amount] (also in
/// KES). Matches backend calculateFee() in fee.ts.
double calculatePlatformFee(double amount) {
  if (amount <= 0) return 0;
  final amountInt = amount.round();
  // amountInt * 5 is exact, so the half-shilling case (KES 1,010 -> 50.5)
  // rounds up, the same as Math.round on the backend.
  final percent = (amountInt * feeRatePercent / 100).round();
  final floored = percent < feeMinKes ? feeMinKes : percent;
  return (floored > feeMaxKes ? feeMaxKes : floored).toDouble();
}

/// Returns the total the buyer pays (amount + payment protection fee).
double calculateTotal(double amount) => amount + calculatePlatformFee(amount);
