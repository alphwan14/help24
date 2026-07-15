/**
 * Promotion campaign state machine — the single transition authority.
 *
 * PURE module: no I/O, no Nest imports (mirrors jobs/settlement-state.ts).
 * CampaignsService performs the DB writes; every transition MUST be validated
 * here first so an illegal jump (e.g. rejected → active) is structurally
 * impossible no matter which endpoint or sweep attempts it.
 *
 *   draft → awaiting_payment → pending_review → active → completed
 *     draft | awaiting_payment → expired      (payment window lapsed)
 *     awaiting_payment → active               (payment success + auto_approve)
 *     pending_review   → rejected             (moderation)
 *     active          ⇄ paused                (owner/admin; resume shifts ends_at)
 *     any non-terminal → cancelled
 */

export const CAMPAIGN_STATUSES = [
  'draft',
  'awaiting_payment',
  'pending_review',
  'active',
  'paused',
  'rejected',
  'completed',
  'expired',
  'cancelled',
] as const;

export type CampaignStatus = (typeof CAMPAIGN_STATUSES)[number];

/** Allowed transitions keyed by current status. Terminal states allow none. */
const TRANSITIONS: Record<CampaignStatus, readonly CampaignStatus[]> = {
  draft:            ['awaiting_payment', 'expired', 'cancelled'],
  awaiting_payment: ['pending_review', 'active', 'expired', 'cancelled'],
  pending_review:   ['active', 'rejected', 'cancelled'],
  active:           ['paused', 'completed', 'cancelled'],
  paused:           ['active', 'completed', 'cancelled'],
  rejected:         [],
  completed:        [],
  expired:          [],
  cancelled:        [],
};

export const TERMINAL_STATUSES: readonly CampaignStatus[] = [
  'rejected',
  'completed',
  'expired',
  'cancelled',
];

export function isCampaignStatus(value: string): value is CampaignStatus {
  return (CAMPAIGN_STATUSES as readonly string[]).includes(value);
}

export function isTerminal(status: CampaignStatus): boolean {
  return TERMINAL_STATUSES.includes(status);
}

export function canTransition(from: CampaignStatus, to: CampaignStatus): boolean {
  return TRANSITIONS[from]?.includes(to) ?? false;
}

/**
 * Throws with a precise message when the transition is illegal.
 * Callers convert to the appropriate HTTP exception.
 */
export function assertTransition(from: CampaignStatus, to: CampaignStatus): void {
  if (!canTransition(from, to)) {
    throw new Error(
      `Illegal campaign transition '${from}' → '${to}'. Allowed from '${from}': ` +
        (TRANSITIONS[from]?.length ? TRANSITIONS[from].join(', ') : '(none — terminal state)'),
    );
  }
}

/**
 * Computes the shifted end when resuming a paused campaign: the pause duration
 * is appended so the owner never loses purchased days.
 */
export function shiftedEndOnResume(endsAt: Date, pausedAt: Date, now: Date): Date {
  const pausedMs = Math.max(0, now.getTime() - pausedAt.getTime());
  return new Date(endsAt.getTime() + pausedMs);
}

/** Whole days remaining, floored at 0 (display helper used by API responses). */
export function daysRemaining(endsAt: Date | null, now: Date): number {
  if (!endsAt) return 0;
  const ms = endsAt.getTime() - now.getTime();
  return ms <= 0 ? 0 : Math.ceil(ms / (24 * 60 * 60 * 1000));
}
