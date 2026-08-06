import { NextRequest, NextResponse } from "next/server";
import { createMiddlewareClient } from "@/lib/supabase-middleware";
import { resolveAdminIdentity } from "@/lib/admin-identity";

export async function middleware(request: NextRequest) {
  const response = NextResponse.next({ request });
  const supabase = createMiddlewareClient(request, response);

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const pathname = request.nextUrl.pathname;

  // ── Public routes ─────────────────────────────────────────────────────────
  // Note: /accept-invite is public and intentionally NOT matched below, so it
  // is reachable without a session (the invite token is the authorization).
  if (pathname === "/login") {
    // Redirect already-logged-in admins straight to dashboard
    if (user) {
      const identity = await resolveAdminIdentity(user.id);
      console.log(
        `[Admin Check] subject=${user.id} help24=${identity?.help24UserId ?? "unlinked"} ` +
          `role=${identity?.role ?? "none"} (pre-auth redirect)`
      );
      if (identity?.role === "admin") {
        return NextResponse.redirect(new URL("/dashboard", request.url));
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
  const identity = await resolveAdminIdentity(user.id);

  console.log(
    `[Admin Check] subject=${user.id} help24=${identity?.help24UserId ?? "unlinked"} ` +
      `role=${identity?.role ?? "none"}`
  );

  if (identity?.role !== "admin") {
    console.log(`[Admin Check] Access DENIED for subject ${user.id}`);
    return NextResponse.redirect(new URL("/login?error=unauthorized", request.url));
  }

  console.log(`[Admin Check] Access GRANTED for ${identity.help24UserId}`);
  return response;
}

export const config = {
  matcher: ["/dashboard/:path*", "/login"],
};
