/**
 * Truthful money-state classification for the archive/delete guard (Phase A).
 *
 * PURE + READ-ONLY: no I/O, no writes, no Daraja, no events. It only maps the
 * canonical money statuses to a display/blocking state so the archive guard can
 * return an honest message instead of one generic "held in escrow" string.
 *
 * This does NOT decide whether archive is blocked in production — jobs.service
 * keeps its existing existence-based gate as the authoritative enforcement.
 * `isArchiveBlocked` here is advisory and used only to pick the message + log.
 *
 * Anchors (see the 3.4A audit):
 *   transactions.status  — the movement anchor
 *   escrow.status        — the holding mirror
 *   failure_reason       — distinguishes a reverted failed payout from a fresh hold
 *   activeDispute        — a non-terminal dispute freezes the funds
 */

export type ArchiveMoneyState =
  | 'no_payment'         // nothing secured — safe to archive
  | 'in_escrow'          // funds locked, awaiting completion — blocked
  | 'payout_processing'  // B2C dispatched, awaiting callback confirmation — blocked
  | 'settlement_failed'  // payout attempt reverted with a reason — blocked
  | 'disputed'           // active dispute freezes the funds — blocked
  | 'released'           // provider paid, terminal — safe to archive
  | 'refunded'           // refunded, terminal — safe to archive
  | 'inconsistent';      // split-brain / mismatched — blocked, needs review

export interface ArchiveStateInput {
  txStatus: string | null;
  escrowStatus: string | null;
  failureReason: string | null;
  activeDispute: boolean;
}

/**
 * Classify the money state from canonical statuses. Deterministic precedence:
 * dispute → terminal-consistent → payout in-flight → failed revert → held →
 * no-payment → inconsistent (any remaining mismatch is split-brain).
 */
export function classifyArchiveMoneyState(i: ArchiveStateInput): ArchiveMoneyState {
  if (i.activeDispute) return 'disputed';

  const t = i.txStatus;
  const e = i.escrowStatus;
  const failed = !!i.failureReason;

  if (t == null && e == null) return 'no_payment';

  // Terminal, both sides agree.
  if (t === 'released' && e === 'released') return 'released';
  if (t === 'refunded' && e === 'refunded') return 'refunded';

  // Payout dispatched, awaiting confirmation (both sides agree).
  if (t === 'payout_pending' && e === 'payout_pending') return 'payout_processing';

  // Held: escrow locked with a paid/pending tx. A failure_reason means a payout
  // was attempted and reverted, which the user must be told about explicitly.
  if (e === 'locked' && (t === 'paid' || t === 'pending')) {
    return failed ? 'settlement_failed' : 'in_escrow';
  }

  // No money secured (no escrow row, tx never succeeded).
  if (e == null && (t === 'failed' || t === 'pending' || t == null)) return 'no_payment';

  // Anything else — released/paid/payout_pending disagreeing across the two
  // records — is a split-brain state that must never read as settled.
  return 'inconsistent';
}

const BLOCKING: ReadonlySet<ArchiveMoneyState> = new Set<ArchiveMoneyState>([
  'disputed',
  'in_escrow',
  'payout_processing',
  'settlement_failed',
  'inconsistent',
]);

/** Advisory: does this state represent money that should block archive/delete? */
export function isArchiveBlocked(state: ArchiveMoneyState): boolean {
  return BLOCKING.has(state);
}

/** Truthful, user-facing message for a blocking money state. */
export function archiveBlockMessage(state: ArchiveMoneyState): string {
  switch (state) {
    case 'payout_processing':
      return 'Payout has been initiated and is awaiting confirmation.';
    case 'in_escrow':
      return 'Funds are securely held in escrow.';
    case 'settlement_failed':
      return 'Payout attempt failed and needs attention. Support has been notified.';
    case 'disputed':
      return 'This job has an active dispute and cannot be removed until resolution.';
    case 'inconsistent':
      return 'This payment needs review by support.';
    default:
      // released / refunded / no_payment are not blocking; defensive fallback for
      // a rare multi-transaction divergence where the gate blocks but the latest
      // transaction reads terminal.
      return 'Funds are currently held. Resolve or complete the job before removing it.';
  }
}
