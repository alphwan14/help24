"use server";

import { cookies } from "next/headers";
import { revalidatePath } from "next/cache";
import {
  ADMIN_TOKEN_COOKIE,
  ApiError,
  adminRequest,
  type AdminRole,
  type CreateInviteResult,
  type LinkCandidate,
  type LinkResult,
} from "./api";

/**
 * Server Actions for invite-based admin management. Privileged writes go through
 * the RBAC-protected NestJS API with the bearer token from the httpOnly cookie.
 * Invite acceptance is not here: it is a plain form POST to
 * app/accept-invite/submit/route.ts (lib/invite-acceptance.ts explains why).
 */

export type ActionResult<T = undefined> = {
  ok: boolean;
  error?: string;
  data?: T;
};

function fail<T = undefined>(err: unknown): ActionResult<T> {
  if (err instanceof ApiError) return { ok: false, error: err.message };
  return { ok: false, error: "Unexpected error. Please try again." };
}

// ── super_admin: invites & user management ──────────────────────────────────

export async function sendInvite(
  formData: FormData,
): Promise<ActionResult<CreateInviteResult>> {
  const email = String(formData.get("email") ?? "").trim();
  const role = String(formData.get("role") ?? "") as AdminRole;
  const help24UserId = String(formData.get("help24UserId") ?? "").trim();
  if (!help24UserId) return { ok: false, error: "Choose the Help24 account this invitation is for." };
  if (!email) return { ok: false, error: "Enter an email address." };
  if (!role) return { ok: false, error: "Choose a role." };

  try {
    const data = await adminRequest<CreateInviteResult>("/admin/invite", {
      method: "POST",
      body: JSON.stringify({ email, role, help24UserId }),
    });
    revalidatePath("/dashboard/users/admins");
    return { ok: true, data };
  } catch (err) {
    return fail(err);
  }
}

// ── super_admin: linking a dashboard login to a Help24 person ───────────────

/** Find the Help24 person a login is for. The backend refuses non-super-admins. */
export async function searchPeople(query: string): Promise<ActionResult<LinkCandidate[]>> {
  const q = query.trim();
  if (q.length < 2) return { ok: true, data: [] };
  try {
    const data = await adminRequest<LinkCandidate[]>(`/admin/identity/people?q=${encodeURIComponent(q)}`);
    return { ok: true, data };
  } catch (err) {
    return fail(err);
  }
}

/** Link a login to a person; the backend records the acting super admin. */
export async function linkDashboardLogin(
  authSubject: string,
  help24UserId: string,
): Promise<ActionResult<LinkResult>> {
  try {
    const data = await adminRequest<LinkResult>("/admin/identity/links", {
      method: "POST",
      body: JSON.stringify({ authSubject, help24UserId }),
    });
    revalidatePath("/dashboard/users/admins");
    return { ok: true, data };
  } catch (err) {
    return fail(err);
  }
}

export async function revokeInvite(id: string): Promise<ActionResult> {
  try {
    await adminRequest(`/admin/invites/${id}`, { method: "DELETE" });
    revalidatePath("/dashboard/users/admins");
    return { ok: true };
  } catch (err) {
    return fail(err);
  }
}

export async function updateAdminRole(
  id: string,
  role: AdminRole,
): Promise<ActionResult> {
  try {
    await adminRequest(`/admin/users/${id}/role`, {
      method: "PATCH",
      body: JSON.stringify({ role }),
    });
    revalidatePath("/dashboard/users/admins");
    return { ok: true };
  } catch (err) {
    return fail(err);
  }
}

export async function deactivateAdmin(id: string): Promise<ActionResult> {
  try {
    await adminRequest(`/admin/users/${id}`, { method: "DELETE" });
    revalidatePath("/dashboard/users/admins");
    return { ok: true };
  } catch (err) {
    return fail(err);
  }
}

// ── Auth token management ────────────────────────────────────────────────────

/**
 * Clear the arbitration bearer token cookie. Called by AdminShell on mismatch
 * detection (when the stored token belongs to a different account). Sign-out
 * clears it through DELETE /api/admin/session instead — a Server Action can
 * stall behind Next's router queue (see that route).
 * Idempotent — safe to call even when no cookie is present.
 */
export async function clearArbitrationToken(): Promise<void> {
  const store = await cookies();
  store.delete(ADMIN_TOKEN_COOKIE);
  revalidatePath("/dashboard");
}
