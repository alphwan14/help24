"use server";

import { revalidatePath } from "next/cache";
import { ApiError, adminRequest } from "./api";

/**
 * Trust & Safety writes — Server Actions only.
 *
 * Every write goes to the RBAC-protected NestJS API with the admin token read
 * server-side from its httpOnly cookie, exactly like lib/disputes-actions.ts.
 * The backend checks the role (a ban needs super_admin), and the database
 * writes the ledger row in the same transaction as the change — there is no
 * path from this dashboard to moderation state that skips either.
 *
 * Results are `{ ok, error?, data? }` so dialogs can show a refusal inline
 * instead of throwing past the user.
 */

export type ActionResult<T = unknown> = { ok: boolean; error?: string; data?: T };

function fail(err: unknown): ActionResult<never> {
  if (err instanceof ApiError) return { ok: false, error: err.message };
  return { ok: false, error: "Unexpected error. Please try again." };
}

const BASE = "/dashboard/trust-safety";

function refreshReport(id: string) {
  revalidatePath(`${BASE}/reports/${id}`);
  revalidatePath(`${BASE}/reports`);
  revalidatePath(`${BASE}/queue`);
}

function refreshUser(userId: string) {
  revalidatePath(`${BASE}/users/${userId}`);
  revalidatePath(`${BASE}/suspended`);
  revalidatePath(`${BASE}/banned`);
  revalidatePath(`${BASE}/restricted`);
  revalidatePath(`${BASE}/audit`);
  revalidatePath("/dashboard/users");
}

// ── Reports ──────────────────────────────────────────────────────────────────

export type TriageInput = {
  status?: "under_review" | "action_required";
  severity?: "low" | "medium" | "high" | "critical";
  assign?: "me" | "none";
  assign_to?: string;
  reason?: string;
};

export async function triageReportAction(reportId: string, input: TriageInput): Promise<ActionResult> {
  try {
    const data = await adminRequest(`/admin/moderation/reports/${reportId}/triage`, {
      method: "POST",
      body: JSON.stringify(input),
    });
    refreshReport(reportId);
    return { ok: true, data };
  } catch (err) {
    return fail(err);
  }
}

export async function resolveReportAction(
  reportId: string,
  input: { outcome: "resolved" | "dismissed"; reason: string; internal_note?: string },
): Promise<ActionResult> {
  if (input.reason.trim().length < 5) return { ok: false, error: "Give a reason of at least 5 characters." };
  try {
    const data = await adminRequest(`/admin/moderation/reports/${reportId}/resolve`, {
      method: "POST",
      body: JSON.stringify({ ...input, reason: input.reason.trim(), internal_note: input.internal_note?.trim() || undefined }),
    });
    refreshReport(reportId);
    revalidatePath(`${BASE}/audit`);
    return { ok: true, data };
  } catch (err) {
    return fail(err);
  }
}

export async function addReportNoteAction(reportId: string, note: string): Promise<ActionResult> {
  if (!note.trim()) return { ok: false, error: "Write a note first." };
  try {
    await adminRequest(`/admin/moderation/reports/${reportId}/notes`, {
      method: "POST",
      body: JSON.stringify({ note: note.trim() }),
    });
    refreshReport(reportId);
    return { ok: true };
  } catch (err) {
    return fail(err);
  }
}

// ── Accounts ─────────────────────────────────────────────────────────────────

export type SanctionInput = {
  kind: "warning" | "suspension" | "ban" | "messaging" | "marketplace";
  reason: string;
  internal_note?: string;
  duration_days?: number;
  report_id?: string;
  resolve_report?: boolean;
  hide_listings?: boolean;
};

export async function sanctionUserAction(userId: string, input: SanctionInput): Promise<ActionResult> {
  if (input.reason.trim().length < 10) {
    return { ok: false, error: "The reason is shown to the person — write at least a sentence (10+ characters)." };
  }
  try {
    const data = await adminRequest(`/admin/moderation/users/${encodeURIComponent(userId)}/sanctions`, {
      method: "POST",
      body: JSON.stringify({
        ...input,
        reason: input.reason.trim(),
        internal_note: input.internal_note?.trim() || undefined,
      }),
    });
    refreshUser(userId);
    if (input.report_id) refreshReport(input.report_id);
    return { ok: true, data };
  } catch (err) {
    return fail(err);
  }
}

export async function addUserNoteAction(userId: string, note: string): Promise<ActionResult> {
  if (!note.trim()) return { ok: false, error: "Write a note first." };
  try {
    await adminRequest(`/admin/moderation/users/${encodeURIComponent(userId)}/notes`, {
      method: "POST",
      body: JSON.stringify({ note: note.trim() }),
    });
    refreshUser(userId);
    return { ok: true };
  } catch (err) {
    return fail(err);
  }
}

export async function liftRestrictionAction(
  restrictionId: string,
  userId: string,
  input: { reason: string; internal_note?: string },
): Promise<ActionResult> {
  if (input.reason.trim().length < 10) return { ok: false, error: "Explain why in at least 10 characters." };
  try {
    const data = await adminRequest(`/admin/moderation/restrictions/${restrictionId}/lift`, {
      method: "POST",
      body: JSON.stringify({ reason: input.reason.trim(), internal_note: input.internal_note?.trim() || undefined }),
    });
    refreshUser(userId);
    return { ok: true, data };
  } catch (err) {
    return fail(err);
  }
}

// ── Content ──────────────────────────────────────────────────────────────────

export async function setContentStateAction(
  contentType: "post" | "message",
  contentId: string,
  action: "remove" | "restore",
  input: { reason: string; internal_note?: string; report_id?: string; owner_user_id?: string },
): Promise<ActionResult> {
  if (input.reason.trim().length < 10) return { ok: false, error: "Explain why in at least 10 characters." };
  try {
    const data = await adminRequest(`/admin/moderation/content/${contentType}/${contentId}/${action}`, {
      method: "POST",
      body: JSON.stringify({
        reason: input.reason.trim(),
        internal_note: input.internal_note?.trim() || undefined,
        report_id: input.report_id,
      }),
    });
    if (input.report_id) refreshReport(input.report_id);
    if (input.owner_user_id) refreshUser(input.owner_user_id);
    return { ok: true, data };
  } catch (err) {
    return fail(err);
  }
}
