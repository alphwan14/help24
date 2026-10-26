import { NextRequest, NextResponse } from "next/server";
import { createMiddlewareClient } from "@/lib/supabase-middleware";
import { resolveAdminAccess, resolveAdminIdentity, type AccessDenial } from "@/lib/admin-identity";
import { DASHBOARD_HOME } from "@/lib/routes";

/** The ?error= the login page explains for each refusal (app/login/page.tsx). */
const DENIAL_PARAM: Record<AccessDenial, string> = {
  unlinked: "not-linked",
  not_admin: "unauthorized",
  unavailable: "unavailable",
};

/**
 * Server-Timing for the admin gate: the session check (`auth`), the identity
 * lookup (`gate`) and the whole of middleware (`mw`). Visible in DevTools →
 * Network → Timing and to `performance.getEntriesByType("resource")`, so a slow
 * navigation can be attributed to the gate or ruled out without guessing.
 * Durations only — nothing about who the admin is.
 */
function withTiming<T extends NextResponse>(res: T, t: { start: number; auth?: number; gate?: number }): T {
  const parts = [
    t.auth != null && `auth;dur=${t.auth.toFixed(1)};desc="session check"`,
    t.gate != null && `gate;dur=${t.gate.toFixed(1)};desc="admin identity"`,
    `mw;dur=${(performance.now() - t.start).toFixed(1)};desc="middleware"`,
  ].filter(Boolean);
  res.headers.set("Server-Timing", parts.join(", "));
  return res;
}

export async function middleware(request: NextRequest) {
  const timing: { start: number; auth?: number; gate?: number } = { start: performance.now() };
  const response = NextResponse.next({ request });
  const supabase = createMiddlewareClient(request, response);

  const {
    data: { user },
  } = await supabase.auth.getUser();
  timing.auth = performance.now() - timing.start;

  const pathname = request.nextUrl.pathname;

  // ── Public routes ─────────────────────────────────────────────────────────
  // /accept-invite is public — the invite token is the authorization. It is
  // matched only so the getUser() above can refresh and WRITE the session
  // cookies: the page reads the session to send an already-signed-in admin
  // past a used invitation, and a refresh it could not persist would spend
  // the refresh token and get the session revoked on reuse.
  if (pathname === "/accept-invite") return response;

  if (pathname === "/login") {
    // Redirect already-logged-in admins straight to dashboard
    if (user) {
      const identity = await resolveAdminIdentity(user.id);
      console.log(
        `[Admin Check] subject=${user.id} help24=${identity?.help24UserId ?? "unlinked"} ` +
          `role=${identity?.role ?? "none"} (pre-auth redirect)`
      );
      if (identity?.role === "admin") {
        return NextResponse.redirect(new URL(DASHBOARD_HOME, request.url));
      }
    }
    return response;
  }

  // ── Protected routes ──────────────────────────────────────────────────────
  if (!user) {
    console.log("[Admin Check] No session — redirecting to /login");
    return NextResponse.redirect(new URL("/login", request.url));
  }

  // Resolved from the session's auth.users id via user_auth_identities, NOT from
  // the session's email. The email path made one user-writable string decide who
  // is an admin; see lib/admin-identity.ts for the full reasoning.
  const gateStart = performance.now();
  const access = await resolveAdminAccess(user.id);
  timing.gate = performance.now() - gateStart;
  const ms = `auth=${timing.auth.toFixed(0)}ms gate=${timing.gate.toFixed(0)}ms`;

  if (!access.ok) {
    console.log(`[Admin Check] Access DENIED for subject ${user.id} (${access.reason}) ${ms}`);
    // Every reason denies. The query only chooses what the person is told:
    // a correct password on an unlinked login is not "no admin privileges".
    return withTiming(NextResponse.redirect(new URL(`/login?error=${DENIAL_PARAM[access.reason]}`, request.url)), timing);
  }

  const identity = access.identity;
  console.log(`[Admin Check] Access GRANTED for ${identity.help24UserId} ${ms}`);
  return withTiming(response, timing);
}

export const config = {
  matcher: ["/dashboard/:path*", "/login", "/accept-invite"],
};
