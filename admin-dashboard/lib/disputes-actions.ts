"use server";

import { cookies } from "next/headers";
import { revalidatePath } from "next/cache";
import {
  ADMIN_TOKEN_COOKIE,
  ApiError,
  adminRequest,
  getCurrentAdmin,
} from "./api";

/**
 * Server Actions for all dispute WRITES + admin-token session management.
 *
 * Every write goes through the RBAC-protected NestJS API with the bearer token
 * read server-side from the httpOnly cookie. Actions return structured results
 * ({ ok, error? }) instead of throwing, so client components can render errors
 * inline. revalidatePath refreshes the affected Server Component after a write.
 */

const TWELVE_HOURS = 60 * 60 * 12;

export type ActionResult<T = undefined> = {
  ok: boolean;
  error?: string;
  data?: T;
};

function toResult<T = undefined>(err: unknown): ActionResult<T> {
  if (err instanceof ApiError) return { ok: false, error: err.message };
  return { ok: false, error: "Unexpected error. Please try again." };
}

// ── Session: connect / disconnect the admin bearer token ─────────────────────

export type ConnectState = { ok: boolean; error?: string; email?: string };

/** useActionState-compatible: validates the token, then stores it httpOnly. */
export async function connectArbitration(
  _prev: ConnectState,
  formData: FormData,
): Promise<ConnectState> {
  const token = String(formData.get("token") ?? "").trim();
  if (!token) return { ok: false, error: "Enter your admin access token." };

  const admin = await getCurrentAdmin(token);
  if (!admin) return { ok: false, error: "Invalid or inactive admin token." };

  const store = await cookies();
  store.set(ADMIN_TOKEN_COOKIE, token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: TWELVE_HOURS,
  });

  revalidatePath("/dashboard/disputes");
  return { ok: true, email: admin.email };
}

export async function disconnectArbitration(): Promise<void> {
  const store = await cookies();
  store.delete(ADMIN_TOKEN_COOKIE);
  revalidatePath("/dashboard/disputes");
}

// ── Case lifecycle writes ────────────────────────────────────────────────────

export async function assignDispute(id: string): Promise<ActionResult> {
  try {
    await adminRequest(`/disputes/${id}/assign`, { method: "POST" });
    revalidatePath(`/dashboard/disputes/${id}`);
    return { ok: true };
  } catch (err) {
    return toResult(err);
  }
}

export type DecisionInput = {
  decisionType: "FULL_RELEASE" | "FULL_REFUND" | "PARTIAL_SPLIT" | "ESCALATE";
  providerAmount?: number;
  clientRefundAmount?: number;
  reasoning: string;
};

export async function decideDispute(
  id: string,
  input: DecisionInput,
): Promise<ActionResult<{ decision_id: string; message: string }>> {
  try {
    // Map the dashboard's camelCase to the backend's snake_case contract.
    const body: Record<string, unknown> = {
      decision_type: input.decisionType,
      reasoning: input.reasoning,
    };
    if (input.decisionType === "PARTIAL_SPLIT") {
      body.provider_amount = input.providerAmount;
      body.client_refund_amount = input.clientRefundAmount;
    }

    const data = await adminRequest<{ decision_id: string; message: string }>(
      `/disputes/${id}/decision`,
      { method: "POST", body: JSON.stringify(body) },
    );
    revalidatePath(`/dashboard/disputes/${id}`);
    revalidatePath("/dashboard/disputes");
    return { ok: true, data };
  } catch (err) {
    return toResult(err);
  }
}

export async function postDisputeMessage(
  id: string,
  formData: FormData,
): Promise<ActionResult> {
  const message = String(formData.get("message") ?? "").trim();
  // Checkbox/flag from the composer — an internal note is admin-only and never
  // reaches the client/provider.
  const internal = String(formData.get("internal") ?? "") === "true";
  if (!message) return { ok: false, error: "Message cannot be empty." };
  try {
    await adminRequest(`/disputes/${id}/message`, {
      method: "POST",
      body: JSON.stringify({ message, internal }),
    });
    revalidatePath(`/dashboard/disputes/${id}`);
    return { ok: true };
  } catch (err) {
    return toResult(err);
  }
}

/** Ask a party for more evidence; flips the case to awaiting_*_evidence. */
export async function requestDisputeEvidence(
  id: string,
  from: "client" | "provider",
  message: string,
): Promise<ActionResult> {
  const msg = message.trim();
  if (!msg) return { ok: false, error: "Describe what evidence you need." };
  try {
    await adminRequest(`/disputes/${id}/request-evidence`, {
      method: "POST",
      body: JSON.stringify({ from, message: msg }),
    });
    revalidatePath(`/dashboard/disputes/${id}`);
    revalidatePath("/dashboard/disputes");
    return { ok: true };
  } catch (err) {
    return toResult(err);
  }
}

/** Mark a single evidence item as reviewed by the current admin. */
export async function markEvidenceReviewed(
  id: string,
  evidenceId: string,
): Promise<ActionResult> {
  try {
    await adminRequest(`/disputes/${id}/evidence/${evidenceId}/reviewed`, {
      method: "PATCH",
    });
    revalidatePath(`/dashboard/disputes/${id}`);
    return { ok: true };
  } catch (err) {
    return toResult(err);
  }
}

export async function addDisputeEvidence(
  id: string,
  formData: FormData,
): Promise<ActionResult> {
  const type = String(formData.get("type") ?? "text") as
    | "image"
    | "video"
    | "text"
    | "system_chat";
  const uploaderType = String(formData.get("uploader_type") ?? "admin") as
    | "client"
    | "provider"
    | "admin"
    | "system";
  const fileUrl = String(formData.get("file_url") ?? "").trim();
  const content = String(formData.get("content") ?? "").trim();

  const body: Record<string, unknown> = { type, uploader_type: uploaderType };
  if (fileUrl) body.file_url = fileUrl;
  if (content) body.content = content;

  try {
    await adminRequest(`/disputes/${id}/evidence`, {
      method: "POST",
      body: JSON.stringify(body),
    });
    revalidatePath(`/dashboard/disputes/${id}`);
    return { ok: true };
  } catch (err) {
    return toResult(err);
  }
}
