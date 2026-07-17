/**
 * Phase 3.4A — the ONE canonical, read-only derived settlement display state.
 *
 * PURE + READ-ONLY: no I/O, no writes, no Daraja, no events. Mobile and admin
 * consume this instead of each inferring money settlement from posts.status,
 * disputes.status, transactions.status or escrow.status individually.
 *
 * Authoritative records (see the audit):
 *   transactions.status — the movement anchor
 *   escrow.status       — the holding mirror
 *   failure_reason      — distinguishes a reverted failed payout from a fresh hold
 *   activeDispute       — a non-terminal dispute freezes the funds
 *   latestDecisionType  — FULL_RELEASE | FULL_REFUND | PARTIAL_SPLIT | ESCALATE
 * posts.status / job_completions are corroborating only and are NOT inputs here.
 *
 * `can_archive` is ADVISORY and mirrors the exact archivePost enforcement gate
 * (activeDispute || tx∈{paid,payout_pending} || escrow∈{locked,payout_pending}),
 * so the two never disagree. archivePost is NOT refactored to use this until the
 * parity test proves exact agreement (Phase C P4).
 */

export type SettlementStateName =
  | 'no_payment'         // nothing secured
  | 'awaiting_payment'   // STK in flight, not yet confirmed
  | 'in_escrow'          // funds locked, awaiting completion
  | 'payout_processing'  // B2C dispatched, awaiting callback confirmation
  | 'settlement_failed'  // payout attempt reverted with a reason
  | 'disputed'           // active dispute freezes the funds
  | 'released'           // provider paid, terminal
  | 'refunded'           // full refund, terminal
  | 'split_settled'      // partial split recorded; provider share owed (manual)
  | 'inconsistent';      // split-brain / mismatched records

export interface SettlementInput {
  txStatus: string | null;
  escrowStatus: string | null;
  failureReason: string | null;
  activeDispute: boolean;
  latestDecisionType: string | null;
  amount: number | null;
  fee: number | null;
  totalPaid: number | null;
  providerAmount: number | null;
  clientRefund: number | null;
  paidAt: string | null;
  releasedAt: string | null;
  disputedAt: string | null;
  resolvedAt: string | null;
}

export interface SettlementState {
  state: SettlementStateName;
  label: string;
  explanation: string;
  can_archive: boolean;
  attention_required: boolean;
  attention_reason: string | null;
  is_terminal: boolean;
  transaction_status: string | null;
  escrow_status: string | null;
  decision_type: string | null;
  amounts: {
    amount: number | null;
    fee: number | null;
    total_paid: number | null;
    provider_amount: number | null;
    client_refund: number | null;
    /** For split_settled: the provider's share recorded but NOT auto-paid. */
    provider_owed: number | null;
  };
  timestamps: {
    paid_at: string | null;
    released_at: string | null;
    disputed_at: string | null;
    resolved_at: string | null;
  };
}

interface StateMeta {
  label: string;
  explanation: string;
  attention: boolean;
  attentionReason: string | null;
  terminal: boolean;
}

const META: Record<SettlementStateName, StateMeta> = {
  no_payment:        { label: 'No payment',          explanation: 'No payment has been secured for this job.',                                   attention: false, attentionReason: null,                  terminal: true },
  awaiting_payment:  { label: 'Payment in progress', explanation: 'Waiting for the M-Pesa payment to be confirmed.',                             attention: false, attentionReason: null,                  terminal: false },
  in_escrow:         { label: 'Payment protected',   explanation: 'The money is held safely by Help24 until the work is approved.',              attention: false, attentionReason: null,                  terminal: false },
  payout_processing: { label: 'Payout processing',   explanation: 'Payout has been initiated and is awaiting confirmation.',                     attention: false, attentionReason: null,                  terminal: false },
  settlement_failed: { label: 'Payout failed',       explanation: 'Payout attempt failed and needs attention. Support has been notified.',       attention: true,  attentionReason: 'payout_failed',       terminal: false },
  disputed:          { label: 'In dispute',          explanation: 'Funds are frozen while an admin reviews the dispute.',                        attention: false, attentionReason: null,                  terminal: false },
  released:          { label: 'Released',            explanation: 'Provider payout completed.',                                                  attention: false, attentionReason: null,                  terminal: true },
  refunded:          { label: 'Refunded',            explanation: 'Refund completed.',                                                           attention: false, attentionReason: null,                  terminal: true },
  split_settled:     { label: 'Split settled',       explanation: "Split decision recorded — the provider's share requires settlement attention.", attention: true, attentionReason: 'provider_payout_owed', terminal: true },
  inconsistent:      { label: 'Needs review',        explanation: 'This payment needs review by support.',                                       attention: true,  attentionReason: 'split_brain',         terminal: false },
};

/**
 * Deterministic precedence: dispute → terminal-consistent → payout in-flight →
 * held (escrow-locked) → no-escrow cases → inconsistent (any remaining mismatch).
 */
function coreState(i: SettlementInput): SettlementStateName {
  const t = i.txStatus;
  const e = i.escrowStatus;
  const failed = !!i.failureReason;

  // Active dispute freezes the funds. If money already reached a terminal state,
  // an open dispute is a split-brain.
  if (i.activeDispute) {
    if (t === 'released' || t === 'refunded' || e === 'released' || e === 'refunded') {
      return 'inconsistent';
    }
    return 'disputed';
  }

  if (t == null && e == null) return 'no_payment';

  // Terminal — both records agree.
  if (t === 'released' && e === 'released') return 'released';
  if (t === 'refunded' && e === 'refunded') {
    return i.latestDecisionType === 'PARTIAL_SPLIT' ? 'split_settled' : 'refunded';
  }

  // Payout dispatched, awaiting the B2C callback (both agree).
  if (t === 'payout_pending' && e === 'payout_pending') return 'payout_processing';

  // Escrow locked = money held. failure_reason distinguishes a reverted payout.
  if (e === 'locked') {
    if (t === 'paid') return failed ? 'settlement_failed' : 'in_escrow';
    if (t === 'pending') return 'awaiting_payment'; // optimistic escrow, payment not confirmed
    return 'inconsistent'; // escrow locked but tx released/refunded/payout_pending
  }

  // No escrow row.
  if (e == null) {
    if (t === 'pending') return 'awaiting_payment';
    if (t === 'failed' || t == null) return 'no_payment';
    return 'inconsistent'; // tx paid/released/etc. but no escrow
  }

  // Any remaining disagreement (escrow released/refunded/payout_pending/disputed
  // not matching the tx) is split-brain.
  return 'inconsistent';
}

/**
 * Advisory archive permission — mirrors the archivePost enforcement gate EXACTLY:
 * blocked while a dispute is active, the tx is paid/payout_pending, or the escrow
 * is locked/payout_pending. Kept as its own function so a parity test can prove it
 * equals the guard for every input combination.
 */
export function canArchive(i: SettlementInput): boolean {
  if (i.activeDispute) return false;
  const heldTx = i.txStatus === 'paid' || i.txStatus === 'payout_pending';
  const heldEscrow = i.escrowStatus === 'locked' || i.escrowStatus === 'payout_pending';
  return !(heldTx || heldEscrow);
}

export function deriveSettlementState(i: SettlementInput): SettlementState {
  const state = coreState(i);
  const meta = META[state];
  return {
    state,
    label: meta.label,
    explanation: meta.explanation,
    can_archive: canArchive(i),
    attention_required: meta.attention,
    attention_reason: meta.attentionReason,
    is_terminal: meta.terminal,
    transaction_status: i.txStatus,
    escrow_status: i.escrowStatus,
    decision_type: i.latestDecisionType,
    amounts: {
      amount: i.amount,
      fee: i.fee,
      total_paid: i.totalPaid,
      provider_amount: i.providerAmount,
      client_refund: i.clientRefund,
      provider_owed: state === 'split_settled' ? i.providerAmount : null,
    },
    timestamps: {
      paid_at: i.paidAt,
      released_at: i.releasedAt,
      disputed_at: i.disputedAt,
      resolved_at: i.resolvedAt,
    },
  };
}
