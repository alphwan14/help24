import { AdminRole, roleAtLeast } from '../auth/admin-role';

/**
 * THE ADMIN VIEW OF ONE PAYMENT — the rules, with no I/O.
 *
 * AdminPaymentsService loads the records; these turn them into what the
 * dashboard's transaction page shows: one timeline of everything that
 * happened to the job and its money, and the actions an admin may take NOW.
 *
 * An action is offered only when the records say it can work, and only to an
 * admin whose role may take it. The backend checks the same rules again when
 * the action is taken (AdminPaymentsService), so a stale page cannot do harm.
 */

export const DISPUTE_CLOSED = ['resolved', 'resolved_release', 'resolved_refund', 'resolved_partial', 'merged'];

export interface PaymentFacts {
  tx: {
    id: string;
    status: string;
    amount: number | null;
    total_paid: number | null;
    mpesa_receipt: string | null;
    failure_reason: string | null;
    created_at: string;
  };
  /** Every payment attempt on the same job, oldest first (this one included). */
  attempts: Array<{ id: string; status: string; total_paid: number | null; failure_reason: string | null; created_at: string }>;
  post: {
    id: string;
    title: string | null;
    status: string | null;
    created_at: string | null;
    author_user_id: string | null;
    selected_provider_id: string | null;
  } | null;
  escrow: { status: string; released_at: string | null; created_at: string | null } | null;
  completion: {
    id: string;
    status: string;
    created_at: string;
    reviewed_at: string | null;
    auto_approve_at: string | null;
    approved_by: string | null;
  } | null;
  disputes: Array<{
    id: string;
    status: string;
    raised_by_role: string | null;
    opened_by_admin_id: string | null;
    created_at: string;
    escalated_at: string | null;
    resolved_at: string | null;
  }>;
  decisions: Array<{ decision_type: string; decided_by_system: boolean | null; created_at: string }>;
  advance: { status: string; amount: number | null; release_requested_at: string | null; paid_out_at: string | null } | null;
  payoutEvents: Array<{ event_type: string; occurred_at: string; reason: string | null; metadata: Record<string, unknown> | null }>;
  adminActions: Array<{ action_type: string; admin_email: string; admin_role: string; reason: string; created_at: string }>;
}

export type Tone = 'neutral' | 'good' | 'attention' | 'bad';

export interface TimelineEntry {
  at: string;
  title: string;
  detail: string | null;
  tone: Tone;
  /** Set for something an admin did, with who. */
  by: string | null;
}

const kes = (n: number | null | undefined) => (n == null ? '' : `KES ${Math.round(n).toLocaleString('en-KE')}`);

const ADMIN_ACTION_TITLES: Record<string, string> = {
  payout_retried: 'Admin sent the payout again',
  payout_status_checked: 'Admin asked M-Pesa about the payout',
  completion_approved: 'Admin approved the finished work',
  dispute_opened: 'Admin opened a dispute',
  hire_cancelled: 'Admin cancelled the hire',
  manual_settlement_recorded: 'Admin recorded a payment made by hand',
  ruling_applied: 'Admin applied the dispute ruling',
};

const DECISION_TITLES: Record<string, string> = {
  FULL_RELEASE: 'Ruling: full payment to the provider',
  FULL_REFUND: 'Ruling: full refund to the client',
  PARTIAL_SPLIT: 'Ruling: split between both',
  ESCALATE: 'Escalated to a senior admin',
};

/** Everything that happened, oldest first. */
export function buildTimeline(f: PaymentFacts): TimelineEntry[] {
  const out: TimelineEntry[] = [];
  const add = (at: string | null | undefined, title: string, tone: Tone = 'neutral', detail: string | null = null, by: string | null = null) => {
    if (at) out.push({ at, title, detail, tone, by });
  };

  add(f.post?.created_at, 'Request posted');
  for (const a of f.attempts) {
    const mine = a.id === f.tx.id;
    const which = mine ? 'This payment' : 'An earlier payment';
    if (a.status === 'failed') add(a.created_at, `${which} failed`, 'bad', a.failure_reason);
    else if (a.status === 'pending') add(a.created_at, `${which} was started on M-Pesa`, 'attention', 'No answer from M-Pesa yet.');
    else add(a.created_at, `${which}: ${kes(a.total_paid)} paid`, 'good', mine && f.tx.mpesa_receipt ? `M-Pesa ${f.tx.mpesa_receipt}` : null);
  }
  if (f.escrow?.created_at && f.escrow.status !== 'released') add(f.escrow.created_at, 'Money held by Help24', 'good');

  if (f.advance) {
    add(f.advance.release_requested_at, `Materials Advance requested (${kes(f.advance.amount)})`);
    add(f.advance.paid_out_at, 'Materials Advance paid to the provider', 'good');
  }

  if (f.completion) {
    add(f.completion.created_at, 'Provider marked the job as done', 'neutral',
      f.completion.status === 'pending_approval' && f.completion.auto_approve_at
        ? 'Waiting for the client. It approves itself if they do nothing (time shown under the job).'
        : null);
    if (f.completion.status === 'approved') {
      const by = f.completion.approved_by === 'system' ? 'automatically, when the review time ended'
        : f.completion.approved_by === 'admin' ? 'by Help24' : 'by the client';
      add(f.completion.reviewed_at, `Work approved ${by}`, 'good');
    }
    if (f.completion.status === 'disputed') add(f.completion.reviewed_at, 'The client disputed the work', 'attention');
  }

  for (const d of f.disputes) {
    const who = d.opened_by_admin_id ? `by Help24 for the ${d.raised_by_role ?? 'party'}` : `by the ${d.raised_by_role ?? 'party'}`;
    add(d.created_at, `Dispute opened ${who}`, 'attention', 'Money frozen until it is decided.');
    add(d.escalated_at, 'Dispute escalated to a senior admin', 'attention');
    add(d.resolved_at, 'Dispute closed', 'neutral');
  }
  for (const d of f.decisions) {
    add(d.created_at, DECISION_TITLES[d.decision_type] ?? `Ruling: ${d.decision_type}`, 'neutral', d.decided_by_system ? 'By the system' : null);
  }

  for (const e of f.payoutEvents) {
    const code = e.metadata && typeof e.metadata.result_code !== 'undefined' ? ` (M-Pesa code ${String(e.metadata.result_code)})` : '';
    if (e.event_type === 'payout_initiated') add(e.occurred_at, 'Payout to the provider started');
    else if (e.event_type === 'payout_sent_to_processor') add(e.occurred_at, 'Payout sent to M-Pesa');
    else if (e.event_type === 'payout_completed') add(e.occurred_at, 'M-Pesa confirmed the payout', 'good');
    else if (e.event_type === 'payout_failed') add(e.occurred_at, 'M-Pesa refused the payout', 'bad', `${e.reason ?? 'No reason given'}${code}`);
    else if (e.event_type === 'payout_refused') add(e.occurred_at, 'Payout could not start', 'bad', e.reason);
  }
  if (f.escrow?.status === 'released') add(f.escrow.released_at, 'Provider paid; payment complete', 'good');

  for (const a of f.adminActions) {
    add(a.created_at, ADMIN_ACTION_TITLES[a.action_type] ?? a.action_type, 'neutral', a.reason, `${a.admin_email} (${a.admin_role})`);
  }

  return out.sort((x, y) => Date.parse(x.at) - Date.parse(y.at));
}

// ── Actions ───────────────────────────────────────────────────────────────

export type PaymentActionId = 'retry_payout' | 'check_mpesa' | 'approve_completion' | 'open_dispute' | 'cancel_hire';

export interface PaymentAction {
  id: PaymentActionId;
  label: string;
  /** What it will do, said before the admin confirms. */
  explanation: string;
  /** False when the records allow it but this admin's role does not. */
  allowed: boolean;
  /** Why not, when not allowed. */
  blocked_reason: string | null;
}

const PAYING = ['paid', 'payout_pending', 'released', 'disputed', 'refunded'];

export function activeDispute(f: PaymentFacts) {
  return f.disputes.find((d) => !DISPUTE_CLOSED.includes(d.status)) ?? null;
}

/**
 * The actions that make sense for this payment now. Who may take them:
 * moving money or a job's state needs a senior admin; opening a dispute (which
 * freezes money to protect someone, and moves none) is open to every admin.
 */
export function availableActions(f: PaymentFacts, role: AdminRole): PaymentAction[] {
  const senior = roleAtLeast(role, 'senior_admin');
  const out: PaymentAction[] = [];
  const offer = (id: PaymentActionId, label: string, explanation: string, needsSenior: boolean) =>
    out.push({
      id, label, explanation,
      allowed: !needsSenior || senior,
      blocked_reason: needsSenior && !senior ? 'A senior admin takes this action.' : null,
    });

  const dispute = activeDispute(f);
  const tx = f.tx;
  const escrowLocked = f.escrow?.status === 'locked';

  if (tx.status === 'paid' && escrowLocked && !dispute && f.completion?.status === 'approved') {
    offer('retry_payout', 'Retry payout',
      `Sends ${kes(tx.amount)} to the provider on M-Pesa again. It can only go out once: a payout already on its way is refused.`, true);
  }
  if (tx.status === 'payout_pending') {
    offer('check_mpesa', 'Check with M-Pesa',
      'Asks M-Pesa what happened to this payout. Nothing is paid unless M-Pesa confirms it.', true);
  }
  if (tx.status === 'paid' && escrowLocked && !dispute && f.completion?.status === 'pending_approval') {
    offer('approve_completion', 'Approve completion now',
      'Approves the finished work for the client, without waiting for the automatic approval, and starts the payout to the provider. Both are told.', true);
  }
  if ((tx.status === 'paid' || tx.status === 'payout_pending') && !dispute && f.post?.selected_provider_id) {
    offer('open_dispute', 'Open a dispute',
      'Opens a case for the client or the provider and freezes the money until a senior admin decides it in Disputes.', false);
  }
  const anyPaid = f.attempts.some((a) => PAYING.includes(a.status));
  if (!anyPaid && f.post?.status === 'assigned' && f.post.selected_provider_id) {
    offer('cancel_hire', 'Cancel the hire',
      'Removes the provider from this request, which was never paid for, and opens it again so the client can choose someone. The provider is told.', true);
  }
  return out;
}
