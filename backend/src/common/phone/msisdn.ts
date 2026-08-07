/**
 * The single definition of a payable Kenyan mobile number.
 *
 * WHY THIS IS ONE FILE AND NOT THREE COPIES
 * -----------------------------------------
 * This logic existed verbatim in `MpesaService` and `PromotionPaymentsService`,
 * the second carrying the comment "kept identical on purpose" — an instruction
 * to a future reader that only works for as long as somebody obeys it. A third
 * copy was about to be written for payout destinations.
 *
 * That matters more here than duplication normally does. This function decides
 * the exact string handed to Daraja B2C. If two copies ever drift, a provider is
 * MATCHED at one canonical form and PAID at another — or is silently skipped by
 * a backfill that normalises slightly differently from the code that pays them.
 * The SQL in `supabase/migrations/107_payout_destinations_backfill.sql` mirrors
 * this function deliberately, and says so; keep the two in step.
 *
 * Behaviour is unchanged from the original: same strip set, same two rewrite
 * rules, same accept pattern.
 */

/** Canonical form: `254` followed by exactly nine digits. */
export const MSISDN_RE = /^254\d{9}$/;

/**
 * Normalise a raw Kenyan number to `254XXXXXXXXX`, or null if it is not one.
 *
 * Accepts the three shapes people actually type — `+254712345678`,
 * `0712345678`, `712345678` — with spaces, dashes, brackets and a leading plus.
 * Anything else is refused rather than guessed at: a wrong guess here sends
 * money to a stranger, and M-Pesa B2C does not reverse.
 */
export function normalizeMsisdn(raw: string | null | undefined): string | null {
  if (!raw) return null;
  let phone = raw.replace(/[\s\-()+]/g, '');
  if (/^0\d{9}$/.test(phone)) phone = '254' + phone.slice(1);
  else if (/^7\d{8}$/.test(phone)) phone = '254' + phone;
  return MSISDN_RE.test(phone) ? phone : null;
}
