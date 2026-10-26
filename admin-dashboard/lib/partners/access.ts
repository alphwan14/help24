import { createClient } from "@supabase/supabase-js";

/**
 * Who a partner-portal session belongs to. A login is a partner only through
 * partner_logins (migration 128), keyed by the auth subject — never by email,
 * the lesson of the admin gate (lib/admin-identity.ts).
 *
 * Free of `server-only` and `next/headers` so Edge middleware can use it, like
 * lib/admin-identity.ts. Never import it from a client component: it holds
 * the service key.
 */
export type PartnerAgent = {
  id: string;
  code: string;
  kind: "onboarding" | "marketing" | "research";
  display_name: string;
  status: "active" | "suspended";
};

export type PartnerDenial = "not_partner" | "suspended" | "unavailable";

export async function resolvePartnerAccess(
  subject: string,
): Promise<{ ok: true; agent: PartnerAgent } | { ok: false; reason: PartnerDenial }> {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) return { ok: false, reason: "unavailable" };
  const db = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, key, { auth: { persistSession: false } });
  const { data, error } = await db
    .from("partner_logins")
    .select("agent_id, partner_agents(id, code, kind, display_name, status)")
    .eq("auth_subject", subject)
    .maybeSingle();
  if (error) {
    console.error("[partners] identity lookup failed:", error.message);
    return { ok: false, reason: "unavailable" };
  }
  const embedded = (data as { partner_agents?: PartnerAgent | PartnerAgent[] | null } | null)?.partner_agents;
  const agent = Array.isArray(embedded) ? embedded[0] : embedded;
  if (!agent) return { ok: false, reason: "not_partner" };
  if (agent.status !== "active") return { ok: false, reason: "suspended" };
  return { ok: true, agent };
}
