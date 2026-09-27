"use server";

import { revalidatePath } from "next/cache";
import { ApiError, adminRequest } from "./api";

export type ReconcileResult = { ok: boolean; message: string };

/**
 * Ask M-Pesa what happened to a payout that never reported back.
 *
 * Calls POST /admin/reconcile-payout (senior_admin; the backend checks the
 * role). It never releases money on age alone: in production it dispatches
 * Daraja's Transaction Status Query, and the payout settles only if Daraja
 * confirms it completed. Safe to repeat.
 */
export async function reconcilePayoutAction(postId: string): Promise<ReconcileResult> {
  try {
    const res = await adminRequest<{ message?: string }>("/admin/reconcile-payout", {
      method: "POST",
      body: JSON.stringify({ post_id: postId }),
    });
    revalidatePath("/dashboard/payments/escrow");
    return { ok: true, message: res?.message ?? "Asked M-Pesa for the result." };
  } catch (err) {
    if (err instanceof ApiError) return { ok: false, message: err.message };
    return { ok: false, message: "Could not reach the payments service." };
  }
}
