import { NextResponse } from "next/server";
import { resolveAdminAccess } from "@/lib/admin-identity";
import { createSessionWriter } from "@/lib/supabase-server";
import type { GoogleSignInError } from "@/lib/google-sign-in";

export const dynamic = "force-dynamic";

/** The sign-in page's message for each way the admin gate refuses. */
const DENIAL: Record<"unlinked" | "not_admin" | "unavailable", GoogleSignInError> = {
  unlinked: "not-linked",
  not_admin: "google-not-admin",
  unavailable: "unavailable",
};

/**
 * POST /api/admin/google-check → { ok: true } | { ok: false, error }
 *
 * Called by the sign-in page the moment Supabase accepts a Google ID token,
 * before the dashboard opens: is this session a linked Help24 admin? The same
 * gate middleware runs on every request (lib/admin-identity.ts). A session
 * that is not an admin is signed out here — this browser only; the person's
 * other sessions, a partner's portal say, are theirs — so a non-admin's
 * Google sign-in never leaves a dashboard session behind.
 */
export async function POST() {
  const supabase = await createSessionWriter();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ ok: false, error: "google-failed" satisfies GoogleSignInError });

  const access = await resolveAdminAccess(user.id);
  if (access.ok) return NextResponse.json({ ok: true });

  console.log(`[Admin Check] Google sign-in DENIED for subject ${user.id} (${access.reason})`);
  await supabase.auth.signOut({ scope: "local" });
  return NextResponse.json({ ok: false, error: DENIAL[access.reason] });
}
