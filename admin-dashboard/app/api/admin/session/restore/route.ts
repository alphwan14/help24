import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { ADMIN_TOKEN_COOKIE, ApiError, restoreAdminSession } from "@/lib/api";
import { getServerAccessToken } from "@/lib/supabase-server";

export const dynamic = "force-dynamic";

const TWELVE_HOURS = 60 * 60 * 12;

/**
 * POST /api/admin/session/restore
 *
 * Silently re-establishes arbitration access from the authenticated Supabase
 * session — no token pasting, no reconnect prompt. Flow:
 *   1. Read the Supabase access-token (JWT) from cookies, server-side.
 *   2. Hand it to the backend, which verifies it and mints a fresh token.
 *   3. Store that token in the httpOnly cookie (never exposed to client JS).
 *
 * Always responds 200 with { connected }. A failure to restore (no session,
 * not an admin, inactive, no admin record) is a normal "recovery" outcome the
 * caller renders, not an error — so reasons are returned, not thrown.
 */
export async function POST() {
  const accessToken = await getServerAccessToken();
  if (!accessToken) {
    return NextResponse.json({ connected: false, reason: "no-session" });
  }

  try {
    const result = await restoreAdminSession(accessToken);

    const store = await cookies();
    store.set(ADMIN_TOKEN_COOKIE, result.token, {
      httpOnly: true,
      secure: process.env.NODE_ENV === "production",
      sameSite: "lax",
      path: "/",
      maxAge: TWELVE_HOURS,
    });

    return NextResponse.json({
      connected: true,
      email: result.email,
      name: result.name,
      role: result.role,
    });
  } catch (err) {
    // 401 = session unverifiable, 403 = not admin / inactive, 404 = no record.
    const status = err instanceof ApiError ? err.status : 500;
    return NextResponse.json({ connected: false, reason: status });
  }
}
