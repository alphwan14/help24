import { NextResponse } from "next/server";
import { resolveAdminAccess } from "@/lib/admin-identity";
import { createServiceClient, getSessionUser } from "@/lib/supabase-server";

export const dynamic = "force-dynamic";

/** At most one write per admin per this many seconds, however many tabs are open. */
const MIN_GAP_SECONDS = 50;

/**
 * POST /api/admin/presence — "this admin has the console open" (migration 132).
 *
 * Sent once a minute by components/ConsolePresence.tsx while a dashboard tab
 * is visible. The session must pass the same gate as every dashboard page
 * (lib/admin-identity.ts — the identity link, never the email alone); the
 * admin row is then matched by the session's email, the key admin_users and
 * the backend already use. Records a time and nothing else.
 *
 * Always 204: presence is a courtesy, so a failure — including the column not
 * existing before 132 is applied — must never surface in the console.
 */
export async function POST() {
  try {
    const user = await getSessionUser();
    if (!user?.email) return new NextResponse(null, { status: 204 });
    const access = await resolveAdminAccess(user.id);
    if (!access.ok) return new NextResponse(null, { status: 204 });

    const now = new Date();
    const stale = new Date(now.getTime() - MIN_GAP_SECONDS * 1000).toISOString();
    const { error } = await createServiceClient()
      .from("admin_users")
      .update({ last_seen_at: now.toISOString() })
      .ilike("email", user.email)
      .eq("active", true)
      .or(`last_seen_at.is.null,last_seen_at.lt."${stale}"`);
    if (error) console.warn("[presence] not recorded:", error.code, error.message);
  } catch (e) {
    console.warn("[presence] not recorded:", e instanceof Error ? e.message : String(e));
  }
  return new NextResponse(null, { status: 204 });
}
