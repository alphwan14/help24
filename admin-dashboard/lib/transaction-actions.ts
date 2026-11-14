"use server";

import { revalidatePath } from "next/cache";
import { ApiError } from "./api";
import { adminActionRequest } from "./arbitration-session";
import type { PaymentActionId } from "./transaction-types";

export type TransactionActionResult = { ok: boolean; error?: string; message?: string; dispute_id?: string };

const PATHS: Record<PaymentActionId, string> = {
  retry_payout: "retry-payout",
  check_mpesa: "check-mpesa",
  approve_completion: "approve-completion",
  open_dispute: "open-dispute",
  cancel_hire: "cancel-hire",
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Take one action on a payment (POST /admin/transactions/:id/<action>). The
 * backend checks the admin's role and that the action still fits the payment,
 * and records it with the admin's name and the reason before anything moves.
 */
export async function takePaymentAction(
  transactionId: string,
  action: PaymentActionId,
  input: { reason?: string; raised_by?: "client" | "provider" } = {},
): Promise<TransactionActionResult> {
  if (!UUID.test(transactionId) || !(action in PATHS)) return { ok: false, error: "Unknown payment or action." };
  const reason = (input.reason ?? "").trim();
  if (action !== "check_mpesa" && reason.length < 5) return { ok: false, error: "Say why, in a few words (at least 5 characters)." };
  if (action === "open_dispute" && input.raised_by !== "client" && input.raised_by !== "provider") {
    return { ok: false, error: "Choose who the dispute is for." };
  }

  const body: Record<string, string> = {};
  if (action !== "check_mpesa") body.reason = reason;
  if (action === "open_dispute") body.raised_by = input.raised_by!;

  try {
    const res = await adminActionRequest<{ message?: string; dispute_id?: string }>(
      `/admin/transactions/${transactionId}/${PATHS[action]}`,
      { method: "POST", body: JSON.stringify(body) },
    );
    revalidatePath(`/dashboard/payments/${transactionId}`);
    revalidatePath("/dashboard/payments", "layout");
    return { ok: true, message: res?.message ?? "Done.", dispute_id: res?.dispute_id };
  } catch (err) {
    if (err instanceof ApiError) return { ok: false, error: err.message };
    return { ok: false, error: "Could not reach the payments service." };
  }
}
