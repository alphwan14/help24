"use server";

import { ApiError, adminRequest } from "./api";
import type { AdminAlert } from "./alerts";

export type ReviewResult = { ok: boolean; error?: string; alert?: AdminAlert };

/**
 * Mark an alert reviewed (or reopen it) for every admin — POST
 * /admin/alerts/:id/reviews. The fingerprint is the one the admin was looking
 * at: if a record joined or left the alert since, the server refuses, so a
 * review never covers something nobody saw.
 */
export async function reviewAlertAction(
  alertId: string,
  fingerprint: string,
  action: "reviewed" | "reopened",
  note?: string,
): Promise<ReviewResult> {
  if (action === "reviewed" && (note ?? "").trim().length < 5) {
    return { ok: false, error: "Say why it needs nothing more — at least 5 characters." };
  }
  try {
    const alert = await adminRequest<AdminAlert>(`/admin/alerts/${encodeURIComponent(alertId)}/reviews`, {
      method: "POST",
      body: JSON.stringify({ action, fingerprint, note: note?.trim() || undefined }),
    });
    return { ok: true, alert };
  } catch (err) {
    if (err instanceof ApiError) return { ok: false, error: err.message };
    return { ok: false, error: "Could not reach the alert service." };
  }
}
