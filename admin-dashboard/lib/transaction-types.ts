/**
 * The shape of GET /admin/transactions/:id (backend admin/payments). Its own
 * module, with no server-only import, so the page's client parts can use it.
 */

export type PaymentActionId = "retry_payout" | "check_mpesa" | "approve_completion" | "open_dispute" | "cancel_hire";

export interface PaymentAction {
  id: PaymentActionId;
  label: string;
  /** What it will do, said before the admin confirms. */
  explanation: string;
  /** False when the payment allows it but this admin's role does not. */
  allowed: boolean;
  blocked_reason: string | null;
}

export type TimelineTone = "neutral" | "good" | "attention" | "bad";

export interface TimelineEntry {
  at: string;
  title: string;
  detail: string | null;
  tone: TimelineTone;
  /** Set for something an admin did: "email (role)". */
  by: string | null;
}

export interface TransactionDetail {
  transaction: {
    id: string;
    status: string;
    amount: number | null;
    fee: number | null;
    total_paid: number | null;
    phone: string | null;
    mpesa_receipt: string | null;
    receipt_number: string | null;
    failure_reason: string | null;
    created_at: string;
  };
  settlement: {
    state: string;
    label: string;
    explanation: string;
    attention_required: boolean;
    is_terminal: boolean;
    amounts: {
      amount: number | null;
      fee: number | null;
      total_paid: number | null;
      provider_amount: number | null;
      client_refund: number | null;
      provider_owed: number | null;
      advance_paid: number | null;
      held: number | null;
    };
  };
  post: {
    id: string;
    title: string | null;
    type: string | null;
    category: string | null;
    location: string | null;
    price: number | null;
    status: string | null;
    created_at: string | null;
    author_user_id: string | null;
    selected_provider_id: string | null;
    archived_at: string | null;
  } | null;
  client: { id: string; name: string | null; email: string | null; phone_number: string | null } | null;
  provider: { id: string; name: string | null; email: string | null; phone_number: string | null } | null;
  escrow: { status: string; released_at: string | null; created_at: string | null } | null;
  completion: {
    id: string;
    status: string;
    created_at: string;
    reviewed_at: string | null;
    auto_approve_at: string | null;
    approved_by: string | null;
  } | null;
  materials_advance: { status: string; amount: number | null; release_requested_at: string | null; paid_out_at: string | null } | null;
  disputes: Array<{
    id: string;
    status: string;
    raised_by_role: string | null;
    opened_by_admin_id: string | null;
    created_at: string;
    escalated_at: string | null;
    resolved_at: string | null;
  }>;
  attempts: Array<{ id: string; status: string; total_paid: number | null; failure_reason: string | null; created_at: string }>;
  timeline: TimelineEntry[];
  actions: PaymentAction[];
  admin_actions: Array<{ action_type: string; admin_email: string; admin_role: string; reason: string; created_at: string }>;
}
