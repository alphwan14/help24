"use server";

import { cookies } from "next/headers";
import { revalidatePath } from "next/cache";
import {
  ADMIN_TOKEN_COOKIE,
  ApiError,
  adminRequest,
  publicRequest,
  type AcceptInviteResult,
  type AdminRole,
  type CreateInviteResult,
} from "./api";

const TWELVE_HOURS = 60 * 60 * 12;

/**
 * Server Actions for invite-based admin management. Privileged writes go through
 * the RBAC-protected NestJS API with the bearer token from the httpOnly cookie;
 * invite acceptance is public (the invite token is the authorization).
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
  if (!email) return { ok: false, error: "Enter an email address." };
  if (!role) return { ok: false, error: "Choose a role." };

  try {
    const data = await adminRequest<CreateInviteResult>("/admin/invite", {
      method: "POST",
      body: JSON.stringify({ email, role }),
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
 * Clear the arbitration bearer token cookie. Called on sign-out (always) and
 * on mismatch detection (when the stored token belongs to a different account).
 * Idempotent — safe to call even when no cookie is present.
 */
export async function clearArbitrationToken(): Promise<void> {
  const store = await cookies();
  store.delete(ADMIN_TOKEN_COOKIE);
  revalidatePath("/dashboard");
}

// ── Public: accept an invite ─────────────────────────────────────────────────

export type AcceptState = {
  ok: boolean;
  error?: string;
  result?: AcceptInviteResult;
};

/** useActionState-compatible. The hidden `token` field carries the invite token. */
export async function acceptInvite(
  _prev: AcceptState,
  formData: FormData,
): Promise<AcceptState> {
  const token = String(formData.get("token") ?? "").trim();
  const name = String(formData.get("name") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  const confirm = String(formData.get("confirm") ?? "");

  if (!token) return { ok: false, error: "Missing invite token." };
  if (name.length < 2) return { ok: false, error: "Enter your full name." };
  if (password.length < 8)
    return { ok: false, error: "Password must be at least 8 characters." };
  if (password !== confirm)
    return { ok: false, error: "Passwords do not match." };

  try {
    const result = await publicRequest<AcceptInviteResult>(
      "/admin/accept-invite",
      { method: "POST", body: JSON.stringify({ token, name, password }) },
    );

    // Pre-connect arbitration: stash the one-time bearer token in the same
    // httpOnly cookie the dashboard uses, so the new admin lands already
    // connected. The token is NEVER exposed to client JS this way.
    const store = await cookies();
    store.set(ADMIN_TOKEN_COOKIE, result.token, {
      httpOnly: true,
      secure: process.env.NODE_ENV === "production",
      sameSite: "lax",
      path: "/",
      maxAge: TWELVE_HOURS,
    });

    // The token now lives ONLY in the httpOnly cookie. Never return it to the
    // browser — the client just needs to know provisioning succeeded.
    return { ok: true, result: { ...result, token: "" } };
  } catch (err) {
    const e = fail(err);
    return { ok: false, error: e.error };
  }
}
