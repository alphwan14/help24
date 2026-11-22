import "server-only";
import { createServiceClient } from "@/lib/supabase-server";

/**
 * Writes to the security log (public.security_events, migration 146).
 *
 * Best effort by design: a sign-in must never fail because the log could not
 * be written, so every error is swallowed and reported to the server log only.
 * Before migration 146 is applied the insert simply fails and nothing changes.
 */

export type SecurityEventInput = {
  event: "console.opened" | "console.refused" | "sign_in.failed" | "google.refused";
  outcome: "success" | "failure";
  actorKind: "admin" | "partner" | "system";
  email?: string | null;
  role?: string | null;
  adminId?: string | null;
  detail?: Record<string, string | number | boolean | null>;
};

/** Where a request came from, as Vercel reports it. */
export function requestContext(h: Headers) {
  const forwarded = h.get("x-forwarded-for")?.split(",")[0]?.trim();
  const ip = forwarded || h.get("x-real-ip") || null;
  let city = h.get("x-vercel-ip-city");
  try {
    city = city ? decodeURIComponent(city) : null;
  } catch {
    /* keep it as sent */
  }
  return {
    ip: ip && /^[0-9a-fA-F:.]{3,45}$/.test(ip) ? ip : null,
    user_agent: h.get("user-agent")?.slice(0, 512) ?? null,
    country: h.get("x-vercel-ip-country")?.slice(0, 64) ?? null,
    city: city?.slice(0, 128) ?? null,
  };
}

export async function recordSecurityEvent(input: SecurityEventInput, h: Headers): Promise<void> {
  try {
    const db = createServiceClient();
    const email = input.email?.trim().toLowerCase() || null;
    let adminId = input.adminId ?? null;
    let role = input.role ?? null;
    if (!adminId && email && input.actorKind === "admin") {
      const { data } = await db.from("admin_users").select("id, role").ilike("email", likeExact(email)).maybeSingle();
      adminId = (data?.id as string | undefined) ?? null;
      role = role ?? ((data?.role as string | undefined) ?? null);
    }
    const { error } = await db.from("security_events").insert({
      event: input.event,
      outcome: input.outcome,
      actor_kind: input.actorKind,
      admin_id: adminId,
      actor_email: email,
      actor_role: role,
      detail: input.detail ?? {},
      ...requestContext(h),
    });
    if (error) console.warn("[security-log] not recorded:", error.code, error.message);
  } catch (e) {
    console.warn("[security-log] not recorded:", e instanceof Error ? e.message : e);
  }
}

/** An ilike pattern that matches this text exactly (case aside). */
function likeExact(s: string): string {
  return s.replace(/[\\%_]/g, (c) => `\\${c}`);
}

/** Is this address a console admin? Failed attempts on any other address are
 *  not logged: anyone can type anything into a sign-in form. */
export async function isAdminEmail(email: string): Promise<boolean> {
  const { data } = await createServiceClient()
    .from("admin_users")
    .select("id")
    .ilike("email", likeExact(email.trim().toLowerCase()))
    .maybeSingle();
  return Boolean(data);
}
