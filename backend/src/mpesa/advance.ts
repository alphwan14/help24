/**
 * Materials Advance: the rules (migration 139). Pure, no I/O.
 *
 * On a big job the fundi usually needs money for materials before the work
 * can start, and that need is the main reason a fundi asks to be paid
 * directly. Materials Advance answers it inside Help24: the customer pays the
 * whole job once, Help24 holds it, and when the fundi is ready the customer
 * taps "Send materials money". Help24 pays 40% of the job to the fundi and
 * keeps holding the rest until the job is approved.
 *
 * Owner decisions 2026-11-10:
 *   - Jobs of KES 10,000 and up, verified providers only (an approved ID check).
 *   - The customer releases the advance; it is never sent automatically.
 *   - The customer pays once: the usual payment protection fee (fee.ts), no
 *     extra charge. Help24 carries the cost of the second M-Pesa payout.
 *   - If the job fails after the advance went out, the customer gets back
 *     everything Help24 still holds, fee included. The advance itself went to
 *     the fundi for the customer's materials; Help24 pursues the fundi if it
 *     was misused.
 */

export const ADVANCE_MIN_JOB_KES = 10_000;
export const ADVANCE_PERCENT = 40;

/** MATERIALS_ADVANCE_ENABLED=true turns the offer on. Absent means off. */
export function advanceEnabled(raw: string | undefined = process.env.MATERIALS_ADVANCE_ENABLED): boolean {
  return raw?.trim().toLowerCase() === 'true';
}

/** 40% of the job in whole shillings, rounded DOWN: never more than 40%. */
export function advanceAmountFor(jobAmount: number): number {
  return Math.floor((Math.round(jobAmount) * ADVANCE_PERCENT) / 100);
}

export type AdvanceUnavailableReason = 'disabled' | 'too_small' | 'provider_not_verified';

export function advanceEligibility(input: {
  enabled: boolean;
  jobAmount: number;
  providerIdVerified: boolean;
}): { eligible: boolean; reason: AdvanceUnavailableReason | null } {
  if (!input.enabled) return { eligible: false, reason: 'disabled' };
  if (Math.round(input.jobAmount) < ADVANCE_MIN_JOB_KES) return { eligible: false, reason: 'too_small' };
  if (!input.providerIdVerified) return { eligible: false, reason: 'provider_not_verified' };
  return { eligible: true, reason: null };
}

export type AdvanceStatus = 'held' | 'sending' | 'paid_out' | 'cancelled' | 'frozen';

export interface AdvanceRow {
  id: string;
  transaction_id: string;
  post_id: string;
  client_user_id: string;
  provider_user_id: string;
  amount: number;
  status: AdvanceStatus;
  conversation_id: string | null;
  originator_conversation_id: string | null;
  failure_reason: string | null;
  release_requested_at: string | null;
  paid_out_at: string | null;
}

/**
 * What the advance has taken out of the held money: its amount once M-Pesa
 * confirmed it, else nothing. An advance in flight ('sending') is NOT counted
 * here; callers that move money must refuse while one is in flight
 * (advanceInFlight), because its outcome is not known yet.
 */
export function advancePaidOut(row: Pick<AdvanceRow, 'status' | 'amount'> | null): number {
  return row && row.status === 'paid_out' ? row.amount : 0;
}

export function advanceInFlight(row: Pick<AdvanceRow, 'status'> | null): boolean {
  return row?.status === 'sending';
}

/** What Help24 still holds of the job amount (the fee is separate). */
export function heldJobAmount(jobAmount: number, row: Pick<AdvanceRow, 'status' | 'amount'> | null): number {
  return Math.max(0, jobAmount - advancePaidOut(row));
}

/**
 * Can the customer send the advance now? Only while it is held, the payment
 * is confirmed and untouched ('paid': not disputed, not paying out), and no
 * dispute is open. The compare-and-set on the row is what finally decides;
 * this is the check that explains a refusal.
 */
export function canRelease(input: {
  row: Pick<AdvanceRow, 'status'> | null;
  txStatus: string | null;
  activeDispute: boolean;
}): { ok: boolean; reason: ReleaseRefusalReason | null } {
  if (!input.row) return { ok: false, reason: 'no_advance' };
  if (input.activeDispute) return { ok: false, reason: 'disputed' };
  if (input.row.status !== 'held') return { ok: false, reason: 'not_held' };
  if (input.txStatus !== 'paid') return { ok: false, reason: 'payment_not_confirmed' };
  return { ok: true, reason: null };
}

export type ReleaseRefusalReason = 'no_advance' | 'not_held' | 'payment_not_confirmed' | 'disputed';

/** Plain-language refusal for the app (no em dashes: plain_copy rule). */
export function releaseRefusal(reason: ReleaseRefusalReason): string {
  switch (reason) {
    case 'no_advance':
      return 'This job was not paid with Materials Advance.';
    case 'disputed':
      return 'A dispute is open on this job, so the money stays held until it is resolved.';
    case 'payment_not_confirmed':
      return 'The materials money can be sent once your payment is confirmed and the job is still in progress.';
    case 'not_held':
      return 'The materials money has already been sent, or the job has been settled.';
  }
}

/**
 * Is this error "the materials_advances table does not exist" (migration 139
 * not applied yet)? Only then may a reader treat it as "no advance": a table
 * that does not exist cannot hold one. Anything else (a missing column, a
 * network error) is NOT this, and money paths must refuse rather than guess.
 */
export function isMissingTable(error: { code?: string; message?: string } | null | undefined): boolean {
  if (!error) return false;
  if (error.code === '42P01' || error.code === 'PGRST205') return true;
  return /materials_advances/.test(error.message ?? '') &&
    /could not find the table|relation .* does not exist/i.test(error.message ?? '');
}
