import { NextResponse } from "next/server";
import { recordSecurityEvent } from "@/lib/security-log";
import { ApiError, restoreAdminSession } from "@/lib/api";
import { storeArbitrationToken } from "@/lib/arbitration-session";
import { getServerAccessToken } from "@/lib/supabase-server";

export const dynamic = "force-dynamic";

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
export async function POST(request: Request) {
  // The sign-in page sends the token it was just given: its session cookie may
  // not be readable here yet. The backend verifies either one itself.
  const bearer = request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1];
  const accessToken = bearer ?? (await getServerAccessToken());
  if (!accessToken) {
    return NextResponse.json({ connected: false, reason: "no-session" });
  }

  try {
    const result = await restoreAdminSession(accessToken);

    await storeArbitrationToken(result.token);
    await recordSecurityEvent(
      { event: "console.opened", outcome: "success", actorKind: "admin", email: result.email, role: result.role, detail: signInMethod(request) },
      request.headers,
    );

    return NextResponse.json({
      connected: true,
      email: result.email,
      name: result.name,
      role: result.role,
    });
  } catch (err) {
    // 401 = session unverifiable, 403 = not admin / inactive, 404 = no record.
    const status = err instanceof ApiError ? err.status : 500;
    // A real login refused the console (not an admin, inactive, no record).
    if (status === 403 || status === 404) {
      await recordSecurityEvent(
        { event: "console.refused", outcome: "failure", actorKind: "admin", email: tokenEmail(accessToken), detail: { reason: String(status), ...signInMethod(request) } },
        request.headers,
      );
    }
    return NextResponse.json({ connected: false, reason: status });
  }
}

/** The sign-in page says how the person signed in, for the security log. */
function signInMethod(request: Request): { method?: string } {
  const m = request.headers.get("x-h24-sign-in");
  return m === "password" || m === "google" ? { method: m } : {};
}

/** The address inside a Supabase access token, for the security log only. The
 *  backend has just refused this token, so nothing here is trusted for access. */
function tokenEmail(token: string): string | null {
  try {
    const payload = JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8")) as { email?: unknown };
    return typeof payload.email === "string" ? payload.email.slice(0, 254) : null;
  } catch {
    return null;
  }
}
