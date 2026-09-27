/**
 * Money after a ruling — client-safe types for GET /admin/finance/disputes/:id/money.
 */

export type ShareState = "owed" | "paid" | "in_flight" | "not_applicable";

export interface DisputeMoney {
  dispute: { id: string; status: string; closed: boolean };
  ruling: {
    id: string;
    type: "FULL_RELEASE" | "FULL_REFUND" | "PARTIAL_SPLIT";
    provider_amount: number | null;
    client_refund_amount: number | null;
    decided_at: string;
  } | null;
  payment: { id: string; status: string; escrow_status: string | null; total_paid: number | null } | null;
  frozen: boolean;
  can_apply_ruling: boolean;
  shares: {
    provider_payout: { amount: number | null; state: ShareState };
    client_refund: { amount: number | null; state: ShareState };
  };
  legs: Array<{
    id: string;
    direction: string;
    rail: string;
    status: string;
    amount: number;
    reference: string | null;
    created_by: string;
    created_at: string;
    settled_at: string | null;
    environment: string;
  }>;
  history: Array<{
    action_type: string;
    admin_email: string;
    admin_role: string;
    reason: string;
    reference: string | null;
    new_state: Record<string, unknown>;
    created_at: string;
  }>;
  environment: "sandbox" | "production";
}

