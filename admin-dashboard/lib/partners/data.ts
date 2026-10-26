import "server-only";
import { createServiceClient } from "../supabase-server";
import type { ProgressRow } from "./rules";

/**
 * Reads for the partner portal and the admin Partners section. Both surfaces
 * call these — the portal scoped to the signed-in agent, the admin pages to
 * any agent or all of them — so their numbers cannot disagree.
 *
 * Every reader returns `failed` instead of an empty list when the read did
 * not happen: "you have no members" and "we couldn't check" are different
 * statements to someone paid per member.
 */

export type AgentRow = {
  id: string;
  code: string;
  kind: string;
  display_name: string;
  email: string | null;
  phone: string | null;
  status: string;
  created_at: string;
};

export type MemberDetail = { name: string | null; phone: string | null };

export type Loaded<T> = { data: T; failed: boolean };

const PROGRESS_COLUMNS = "member_id, agent_id, method, claimed_at, joined_at, window_ends_at, active_days, posts_14d, offers_14d, account_status";

export async function loadProgress(agentId?: string): Promise<Loaded<ProgressRow[]>> {
  let q = createServiceClient().from("partner_member_progress").select(PROGRESS_COLUMNS).order("claimed_at", { ascending: false }).limit(5000);
  if (agentId) q = q.eq("agent_id", agentId);
  const { data, error } = await q;
  if (error) {
    console.error("[partners] progress unavailable:", error.message);
    return { data: [], failed: true };
  }
  return { data: (data ?? []) as ProgressRow[], failed: false };
}

/** Names and numbers for members — the portal masks them (rules.ts), admins see them whole. */
export async function loadMemberDetails(ids: string[]): Promise<Map<string, MemberDetail>> {
  const out = new Map<string, MemberDetail>();
  const db = createServiceClient();
  for (let i = 0; i < ids.length; i += 100) {
    const { data, error } = await db.from("users").select("id, name, phone_number, phone").in("id", ids.slice(i, i + 100));
    if (error) {
      console.error("[partners] member details unavailable:", error.message);
      break;
    }
    for (const u of data ?? []) {
      out.set(u.id as string, { name: (u.name as string | null) ?? null, phone: ((u.phone_number as string | null) || (u.phone as string | null)) ?? null });
    }
  }
  return out;
}

export async function loadAgents(): Promise<Loaded<AgentRow[]>> {
  const { data, error } = await createServiceClient()
    .from("partner_agents")
    .select("id, code, kind, display_name, email, phone, status, created_at")
    .order("created_at", { ascending: false });
  if (error) {
    console.error("[partners] agents unavailable:", error.message);
    return { data: [], failed: true };
  }
  return { data: (data ?? []) as AgentRow[], failed: false };
}

export async function loadAgent(id: string): Promise<AgentRow | null> {
  const { data, error } = await createServiceClient()
    .from("partner_agents")
    .select("id, code, kind, display_name, email, phone, status, created_at")
    .eq("id", id)
    .maybeSingle();
  if (error) throw new Error(`agent: ${error.message}`);
  return (data as AgentRow | null) ?? null;
}

export type AgentEvent = { action: string; reason: string | null; admin_email: string | null; created_at: string };

export async function loadAgentEvents(id: string): Promise<Loaded<AgentEvent[]>> {
  const { data, error } = await createServiceClient()
    .from("partner_admin_events")
    .select("action, reason, admin_email, created_at")
    .eq("agent_id", id)
    .order("created_at", { ascending: false })
    .limit(50);
  if (error) return { data: [], failed: true };
  return { data: (data ?? []) as AgentEvent[], failed: false };
}

/** Whether the agent has a portal login yet, and the latest invitation. */
export async function loadAccess(id: string): Promise<{ hasLogin: boolean; invite: { expires_at: string; used_at: string | null } | null }> {
  const db = createServiceClient();
  const [login, invite] = await Promise.all([
    db.from("partner_logins").select("agent_id").eq("agent_id", id).maybeSingle(),
    db.from("partner_invites").select("expires_at, used_at").eq("agent_id", id).order("created_at", { ascending: false }).limit(1).maybeSingle(),
  ]);
  return { hasLogin: !!login.data, invite: (invite.data as { expires_at: string; used_at: string | null } | null) ?? null };
}
