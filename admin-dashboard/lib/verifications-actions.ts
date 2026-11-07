"use server";

import { revalidatePath } from "next/cache";
import { ApiError } from "./api";
import { adminActionRequest } from "./arbitration-session";

/**
 * Provider verification decisions — Server Actions only. The backend records
 * the decision through review_provider_verification (migration 135), which
 * also turns on the badge and reopens or keeps hidden the provider's listings,
 * then tells the provider.
 */

export type ActionResult<T = unknown> = { ok: boolean; error?: string; data?: T };

const BASE = "/dashboard/trust-safety/verifications";

export async function reviewVerificationAction(
  id: string,
  decision: "approve" | "reject",
  reason?: string,
): Promise<ActionResult> {
  try {
    const data = await adminActionRequest(`/admin/verifications/${encodeURIComponent(id)}/review`, {
      method: "POST",
      body: JSON.stringify(decision === "reject" ? { decision, reason } : { decision }),
    });
    revalidatePath(BASE);
    revalidatePath(`${BASE}/${id}`);
    revalidatePath("/dashboard");
    return { ok: true, data };
  } catch (err) {
    if (err instanceof ApiError) return { ok: false, error: err.message };
    return { ok: false, error: "Unexpected error. Please try again." };
  }
}
