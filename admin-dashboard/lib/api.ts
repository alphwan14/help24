import "server-only";
import { cookies } from "next/headers";

/**
 * Server-only API client for the NestJS arbitration backend.
 *
 * ARCHITECTURE: NestJS is the single source of truth for disputes. The admin
 * bearer token lives in an httpOnly cookie and is attached here, server-side
 * only — it is NEVER exposed to client JavaScript. All dispute reads happen in
 * Server Components via these readers; all writes happen in Server Actions
 * (lib/disputes-actions.ts) that call adminRequest(). The browser only ever
 * sees rendered HTML and Server-Action results.
 *
 * The `server-only` import makes the build fail loudly if this module is ever
 * imported into a Client Component.
 */

// Backend origin is environment-driven. In production (Vercel) set
// NEXT_PUBLIC_BACKEND_URL to the Render API URL; the localhost value is only a
// dev fallback when no env var is provided.
const BACKEND =
  process.env.BACKEND_URL ??
  process.env.NEXT_PUBLIC_BACKEND_URL ??
  "http://localhost:3000";

export const ADMIN_TOKEN_COOKIE = "h24_admin_token";

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = "ApiError";
  }
}

export async function getAdminToken(): Promise<string | null> {
  const store = await cookies();
  return store.get(ADMIN_TOKEN_COOKIE)?.value ?? null;
}

function safeParse(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

/** Normalize NestJS error bodies ({ message: string | string[] }) to one line. */
function extractMessage(json: unknown): string | null {
  if (json && typeof json === "object" && "message" in json) {
    const m = (json as { message: unknown }).message;
    if (Array.isArray(m)) return m.join("; ");
    if (typeof m === "string") return m;
  }
  return null;
}

/**
 * Core fetch wrapper. Attaches the bearer token, forces no-store (admin data is
 * always live), and converts non-2xx into a typed ApiError with the backend's
 * message. Exported for Server Actions that perform writes.
 */
export async function adminRequest<T>(
  path: string,
  init?: RequestInit & { token?: string },
): Promise<T> {
  const token = init?.token ?? (await getAdminToken());
  if (!token) throw new ApiError(401, "Not connected to the arbitration backend.");

  let res: Response;
  try {
    res = await fetch(`${BACKEND}${path}`, {
      ...init,
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
        ...(init?.headers ?? {}),
      },
      cache: "no-store",
    });
  } catch {
    throw new ApiError(503, "Cannot reach the arbitration backend.");
  }

  const text = await res.text();
  const json = text ? safeParse(text) : null;

  if (!res.ok) {
    throw new ApiError(res.status, extractMessage(json) ?? `Request failed (${res.status}).`);
  }
  return json as T;
}

/**
 * Unauthenticated request to the backend, for PUBLIC endpoints where the
 * authorization is something other than the admin bearer token (e.g. the
 * single-use invite token carried in the path/body). No cookie is read.
 */
export async function publicRequest<T>(
  path: string,
  init?: RequestInit,
): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${BACKEND}${path}`, {
      ...init,
      headers: { "Content-Type": "application/json", ...(init?.headers ?? {}) },
      cache: "no-store",
    });
  } catch {
    throw new ApiError(503, "Cannot reach the arbitration backend.");
  }

  const text = await res.text();
  const json = text ? safeParse(text) : null;

  if (!res.ok) {
    throw new ApiError(res.status, extractMessage(json) ?? `Request failed (${res.status}).`);
  }
  return json as T;
}

// ── Types (mirror backend response shapes) ──────────────────────────────────

export type AdminRole = "support_agent" | "senior_admin" | "super_admin";

export interface AdminMe {
  id: string;
  email: string;
  name: string;
  role: AdminRole;
}

// `type` (not `interface`) so it carries an implicit index signature and is
// assignable to DataTable's `Record<string, unknown>` row constraint.
export type DisputeListItem = {
  id: string;
  status: string;
  priority: string;
  reason: string;
  raised_by_role: string | null;
  assigned_admin_id: string | null;
  created_at: string;
  resolved_at: string | null;
  escalated_at: string | null;
  provider_amount: number | null;
  buyer_refund: number | null;
  sla_age_ms: number;
  posts: { id: string; title: string; price: number; status: string } | null;
  transactions: { id: string; amount: number; total_paid: number; status: string } | null;
};

export interface DisputeDecision {
  id: string;
  decision_type: "FULL_REFUND" | "FULL_RELEASE" | "PARTIAL_SPLIT" | "ESCALATE";
  admin_id: string | null;
  decided_by_system: boolean;
  provider_amount: number | null;
  client_refund_amount: number | null;
  reasoning: string;
  created_at: string;
}

export interface DisputeEvidence {
  id: string;
  type: "image" | "video" | "text" | "system_chat";
  uploader_type: "client" | "provider" | "admin" | "system";
  uploaded_by: string;
  file_url: string | null;
  content: string | null;
  created_at: string;
}

export interface DisputeMessage {
  id: string;
  sender_type: "client" | "provider" | "admin" | "system";
  sender_id: string | null;
  message: string;
  created_at: string;
}

export interface DisputeCase {
  id: string;
  status: string;
  priority: string;
  reason: string;
  raised_by_role: string | null;
  raised_by_user_id: string;
  admin_notes: string | null;
  resolved_by: string | null;
  assigned_admin_id: string | null;
  assigned_at: string | null;
  first_response_at: string | null;
  escalated_at: string | null;
  provider_amount: number | null;
  buyer_refund: number | null;
  created_at: string;
  resolved_at: string | null;
  sla_age_ms: number;
  posts: {
    id: string;
    title: string;
    price: number;
    author_user_id: string;
    selected_provider_id: string;
    status: string;
  } | null;
  transactions: {
    id: string;
    amount: number;
    fee: number;
    total_paid: number;
    status: string;
    mpesa_receipt: string | null;
    created_at: string;
  } | null;
  job_completions: {
    id: string;
    status: string;
    provider_note: string | null;
  } | null;
  buyer: { id: string; name: string | null; phone_number: string | null } | null;
  provider: { id: string; name: string | null; phone_number: string | null } | null;
  assigned_admin: { id: string; name: string; email: string; role: AdminRole } | null;
  evidence: DisputeEvidence[];
  messages: DisputeMessage[];
  decisions: DisputeDecision[];
  chat_context: Array<{
    id: string;
    sender_id: string;
    content: string;
    type: string;
    created_at: string;
  }>;
}

export interface DisputeRecommendation {
  suggested_decision: "FULL_REFUND" | "FULL_RELEASE" | "PARTIAL_SPLIT" | "ESCALATE";
  confidence: number;
  reasoning: string;
  signals: Record<string, unknown>;
}

// ── Admin / invite management types ─────────────────────────────────────────

export type AdminUser = {
  id: string;
  email: string;
  name: string;
  role: AdminRole;
  active: boolean;
  created_at: string;
  last_login_at: string | null;
};

export type PendingInvite = {
  id: string;
  email: string;
  role: AdminRole;
  status: "pending";
  created_at: string;
  expires_at: string;
};

export interface InviteMetadata {
  email: string;
  role: AdminRole;
  status: "validated";
  expires_at: string;
}

export interface AcceptInviteResult {
  email: string;
  role: AdminRole;
  token: string;
  notice: string;
}

export interface RestoreSessionResult {
  email: string;
  name: string;
  role: AdminRole;
  token: string;
}

export interface CreateInviteResult {
  inviteLink: string;
  email: string;
  role: AdminRole;
  expires_at: string;
}

// ── Readers (Server Components) ──────────────────────────────────────────────

/** Public: validate an invite token (no auth). Throws ApiError on invalid/expired. */
export function getInvite(token: string): Promise<InviteMetadata> {
  return publicRequest<InviteMetadata>(`/admin/invite/${encodeURIComponent(token)}`);
}

/**
 * Exchange a verified Supabase access-token (JWT) for a fresh arbitration token.
 * The backend re-verifies the JWT, so this is forge-proof. Throws ApiError with
 * a meaningful status on the genuine recovery cases (401/403/404).
 */
export function restoreAdminSession(accessToken: string): Promise<RestoreSessionResult> {
  return publicRequest<RestoreSessionResult>("/admin/session/restore", {
    method: "POST",
    body: JSON.stringify({ accessToken }),
  });
}

/** super_admin: list all admin_users via the backend. */
export function getAdminUsers(): Promise<AdminUser[]> {
  return adminRequest<AdminUser[]>("/admin/users");
}

/** super_admin: list pending invites. */
export function getPendingInvites(): Promise<PendingInvite[]> {
  return adminRequest<PendingInvite[]>("/admin/invites");
}


/**
 * Returns the admin for the active (or supplied) token, or null if the token is
 * missing/invalid/inactive. Never throws — pages branch on null to show the
 * connect gate.
 */
export async function getCurrentAdmin(token?: string): Promise<AdminMe | null> {
  try {
    return await adminRequest<AdminMe>("/admin/me", token ? { token } : undefined);
  } catch {
    return null;
  }
}

export function getOpenDisputes(status?: string): Promise<DisputeListItem[]> {
  const qs = status ? `?status=${encodeURIComponent(status)}` : "";
  return adminRequest<DisputeListItem[]>(`/disputes/open${qs}`);
}

export function getDispute(id: string): Promise<DisputeCase> {
  return adminRequest<DisputeCase>(`/disputes/${id}`);
}

export function getRecommendation(id: string): Promise<DisputeRecommendation> {
  return adminRequest<DisputeRecommendation>(`/disputes/${id}/recommendation`);
}

export function getEvidence(id: string): Promise<DisputeEvidence[]> {
  return adminRequest<DisputeEvidence[]>(`/disputes/${id}/evidence`);
}

export function getMessages(id: string): Promise<DisputeMessage[]> {
  return adminRequest<DisputeMessage[]>(`/disputes/${id}/messages`);
}
