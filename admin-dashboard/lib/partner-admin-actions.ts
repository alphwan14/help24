"use server";

import { revalidatePath } from "next/cache";
import { getCurrentAdmin } from "./api";
import { partnerPortalUrl } from "./partners/hosts";
import { hashInviteToken, newInviteToken } from "./partners/rules";
import { createServiceClient } from "./supabase-server";

/**
 * Admin actions on partner agents. The admin is confirmed through the backend
 * (/admin/me — the same check every admin page relies on); the database
 * functions (migration 128) check the role again and record who acted.
 * senior_admin or super_admin.
 */

export type PartnerResult = { ok: boolean; error?: string; id?: string; code?: string; inviteUrl?: string; expiresAt?: string };

async function senior(): Promise<{ id: string } | string> {
  const admin = await getCurrentAdmin();
  if (!admin) return "Your admin session could not be confirmed. Reload and try again.";
  if (admin.role !== "senior_admin" && admin.role !== "super_admin") return "Managing partners needs a Senior Admin.";
  return { id: admin.id };
}

function words(message: string | undefined): string {
  const m = /HELP24_PARTNER_[A-Z_]+:\s*(.+)$/.exec(message ?? "");
  if (!m) return "That could not be saved just now. Nothing was changed — please try again.";
  return m[1].charAt(0).toUpperCase() + m[1].slice(1) + ".";
}

async function issue(adminId: string, agentId: string): Promise<PartnerResult> {
  const token = newInviteToken();
  const { data, error } = await createServiceClient().rpc("admin_issue_partner_invite", {
    p_admin_id: adminId,
    p_agent_id: agentId,
    p_token_hash: await hashInviteToken(token),
    p_ttl_hours: 72,
  });
  if (error) return { ok: false, error: words(error.message) };
  // The token is shown to the admin once and never stored anywhere.
  return { ok: true, inviteUrl: `${partnerPortalUrl()}/accept?token=${token}`, expiresAt: (data as { expires_at: string }).expires_at };
}

export async function createPartnerAgentAction(input: {
  name: string;
  kind: string;
  email: string;
  phone: string;
}): Promise<PartnerResult> {
  const who = await senior();
  if (typeof who === "string") return { ok: false, error: who };
  const { data, error } = await createServiceClient().rpc("admin_create_partner_agent", {
    p_admin_id: who.id,
    p_display_name: input.name,
    p_kind: input.kind,
    p_email: input.email,
    p_phone: input.phone,
  });
  if (error) return { ok: false, error: words(error.message) };
  const made = data as { id: string; code: string };
  revalidatePath("/dashboard/partners");
  const invite = input.email.trim() ? await issue(who.id, made.id) : null;
  return { ok: true, id: made.id, code: made.code, inviteUrl: invite?.inviteUrl, expiresAt: invite?.expiresAt, error: invite && !invite.ok ? invite.error : undefined };
}

export async function issuePartnerInviteAction(agentId: string): Promise<PartnerResult> {
  const who = await senior();
  if (typeof who === "string") return { ok: false, error: who };
  const res = await issue(who.id, agentId);
  revalidatePath(`/dashboard/partners/${agentId}`);
  return res;
}

export async function setPartnerStatusAction(agentId: string, status: "active" | "suspended", reason: string): Promise<PartnerResult> {
  const who = await senior();
  if (typeof who === "string") return { ok: false, error: who };
  if (reason.trim().length < 5) return { ok: false, error: "Say why — at least 5 characters." };
  const { error } = await createServiceClient().rpc("admin_set_partner_status", {
    p_admin_id: who.id,
    p_agent_id: agentId,
    p_status: status,
    p_reason: reason.trim(),
  });
  if (error) return { ok: false, error: words(error.message) };
  revalidatePath("/dashboard/partners");
  revalidatePath(`/dashboard/partners/${agentId}`);
  return { ok: true };
}
