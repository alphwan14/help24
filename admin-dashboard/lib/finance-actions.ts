"use server";

import { revalidatePath } from "next/cache";
import { ApiError, adminRequest } from "./api";

export type FinanceResult = { ok: boolean; error?: string; message?: string };

function fail(err: unknown): FinanceResult {
  if (err instanceof ApiError) return { ok: false, error: err.message };
  return { ok: false, error: "Could not reach the payments service." };
}

/**
 * Record that finance paid a ruling's share by hand. senior_admin (the backend
 * checks). The amount is never sent: the database takes it from the ruling.
 */
export async function recordManualSettlementAction(
  transactionId: string,
  disputeId: string,
  input: { direction: "provider_payout" | "client_refund"; reference: string; reason: string },
): Promise<FinanceResult> {
  if (input.reference.trim().length < 3) return { ok: false, error: "Give the payment reference (the M-Pesa code or bank reference)." };
  if (input.reason.trim().length < 5) return { ok: false, error: "Say how it was paid — at least 5 characters." };
  try {
    await adminRequest(`/admin/finance/transactions/${encodeURIComponent(transactionId)}/manual-settlements`, {
      method: "POST",
      body: JSON.stringify({ direction: input.direction, reference: input.reference.trim(), reason: input.reason.trim() }),
    });
    revalidatePath(`/dashboard/disputes/${disputeId}`);
    return { ok: true, message: "Recorded as paid." };
  } catch (err) {
    return fail(err);
  }
}

/** Apply the ruling on record to money a legacy resolve left frozen. senior_admin. */
export async function applyRulingAction(disputeId: string, reason: string): Promise<FinanceResult> {
  if (reason.trim().length < 5) return { ok: false, error: "Give a reason — at least 5 characters." };
  try {
    const res = await adminRequest<{ phase: string; payout: { dispatched: boolean; message: string } | null }>(
      `/admin/finance/disputes/${encodeURIComponent(disputeId)}/apply-ruling`,
      { method: "POST", body: JSON.stringify({ reason: reason.trim() }) },
    );
    revalidatePath(`/dashboard/disputes/${disputeId}`);
    revalidatePath("/dashboard/payments/escrow");
    if (res.payout && !res.payout.dispatched) return { ok: false, error: res.payout.message };
    return { ok: true, message: res.payout?.message ?? "The ruling on record has been applied." };
  } catch (err) {
    return fail(err);
  }
}
