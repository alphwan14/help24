import { NextResponse } from "next/server";
import { resolveAdminAccess } from "@/lib/admin-identity";
import { createSessionWriter, getServerAccessToken } from "@/lib/supabase-server";
import { restoreAdminSession } from "@/lib/api";
import { storeArbitrationToken } from "@/lib/arbitration-session";
import type { GoogleSignInError } from "@/lib/google-sign-in";
import type { ArbitrationIdentity } from "@/lib/arbitration-client";

export const dynamic = "force-dynamic";

/** The sign-in page's message for each way the admin gate refuses. */
const DENIAL: Record<"unlinked" | "not_admin" | "unavailable", GoogleSignInError> = {
  unlinked: "not-linked",
  not_admin: "google-not-admin",
  unavailable: "unavailable",
};

/**
 * POST /api/admin/google-check → { ok: true, identity } | { ok: false, error }
 *
 * Called by the sign-in page the moment Supabase accepts a Google ID token,
 * before the dashboard opens: is this session a linked Help24 admin? The same
 * gate middleware runs on every request (lib/admin-identity.ts). A session
 * that is not an admin is signed out here — this browser only; the person's
 * other sessions, a partner's portal say, are theirs — so a non-admin's
 * Google sign-in never leaves a dashboard session behind.
 *
 * The page sends the access token it was just given as a Bearer header. The
 * session cookie the browser wrote at the same moment was not always readable
 * here yet on a phone, and this answered "Google sign-in didn't finish" to the
 * first try of a real admin. Supabase verifies the token either way.
 *
 * An admin's console access (the backend key) is set here too, so the
 * dashboard opens straight away instead of behind "Opening the console".
 */
export async function POST(request: Request) {
  const bearer = request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1];
  const supabase = await createSessionWriter();
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser(bearer);
  if (!user) {
    console.log(`[Admin Check] Google check found no session (${bearer ? "token" : "cookie"}): ${error?.message ?? "none"}`);
    return NextResponse.json({ ok: false, error: "google-failed" satisfies GoogleSignInError });
  }

  const access = await resolveAdminAccess(user.id);
  if (access.ok) {
    return NextResponse.json({ ok: true, identity: await connect(bearer) });
  }

  console.log(`[Admin Check] Google sign-in DENIED for subject ${user.id} (${access.reason})`);
  await supabase.auth.signOut({ scope: "local" });
  return NextResponse.json({ ok: false, error: DENIAL[access.reason] });
}

/** Mint and store the backend key. A failure here is not a refusal: the
 *  dashboard's own restore (AdminShell) tries again on arrival. */
async function connect(bearer: string | undefined): Promise<ArbitrationIdentity> {
  const token = bearer ?? (await getServerAccessToken());
  if (!token) return { connected: false };
  try {
    const result = await restoreAdminSession(token);
    await storeArbitrationToken(result.token);
    return { connected: true, email: result.email, name: result.name, role: result.role };
  } catch {
    return { connected: false };
  }
}
