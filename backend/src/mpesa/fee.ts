/**
 * Help24's payment protection fee, paid by the customer on top of the job.
 *
 * Owner decision 2026-11-10: 5% of the job, minimum KES 30, maximum
 * KES 1,000. The provider keeps 100% of the agreed price; the fee pays for
 * M-Pesa in (STK Push) and out (B2C) and for holding the money until the job
 * is done. It replaces the flat tiers (20/45/95/195/295), which lost money on
 * mid-size jobs once both M-Pesa legs were counted.
 *
 * Why a floor and not a booking fee or a higher rate on small jobs: M-Pesa
 * costs are close to fixed per job (about KES 23 in and out at KES 1,000,
 * less below it), so 5% alone loses money under roughly KES 460. A floor
 * fixes exactly those jobs and nothing else (it only applies below KES 600),
 * the total never jumps at a price boundary, and the rule is one sentence.
 *
 * Why a cap: big jobs are where a customer and a fundi are most tempted to
 * settle in cash, and KES 2,500 on a KES 50,000 job is worth dodging while
 * KES 1,000 reads as cheap protection. M-Pesa costs about KES 255 there, so
 * the capped fee still clears about KES 745. The cap starts at KES 20,000.
 *
 * MIRRORED in mobile-app/lib/utils/payment_utils.dart, which shows the fee
 * before the customer pays. Change both together; fee.spec.ts and
 * mobile-app/test/payment_utils_test.dart pin the same golden table.
 */
export const FEE_RATE_PERCENT = 5;
export const FEE_MIN_KES = 30;
export const FEE_MAX_KES = 1_000;

/** The smallest job Help24 takes payment for; mpesa.service.ts refuses below it too. */
const MIN_JOB_KES = 100;

export function calculateFee(amount: number): number {
  if (amount < MIN_JOB_KES) {
    throw new RangeError(`Amount must be at least ${MIN_JOB_KES} KES (received ${amount})`);
  }
  // amount * 5 is an exact integer, so the half-shilling case (KES 1,010 ->
  // 50.5) rounds up the same way Dart's round() does on the app side.
  const percent = Math.round((Math.round(amount) * FEE_RATE_PERCENT) / 100);
  return Math.min(FEE_MAX_KES, Math.max(FEE_MIN_KES, percent));
}

export function calculateTotal(amount: number): number {
  return amount + calculateFee(amount);
}
