import { NextRequest, NextResponse } from "next/server";
import { createMiddlewareClient } from "@/lib/supabase-middleware";

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
      const role = await fetchRoleFromDB(supabase, user.email);
      console.log(`[Admin Check] email=${user.email} role_from_db=${role} (pre-auth redirect)`);
      if (role === "admin") {
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

  const role = await fetchRoleFromDB(supabase, user.email);

  console.log(`[Admin Check] email=${user.email} role_from_db=${role}`);

  if (role !== "admin") {
    console.log(`[Admin Check] Access DENIED for ${user.email} (role=${role})`);
    return NextResponse.redirect(new URL("/login?error=unauthorized", request.url));
  }

  console.log(`[Admin Check] Access GRANTED for ${user.email}`);
  return response;
}

/**
 * Fetch role exclusively from public.users (email lookup).
 * Never trusts JWT metadata — DB is the single source of truth.
 */
async function fetchRoleFromDB(
  supabase: ReturnType<typeof createMiddlewareClient>,
  email: string | undefined
): Promise<string> {
  if (!email) {
    console.log("[Admin Check] No email on auth user — denying");
    return "user";
  }

  const { data, error } = await supabase
    .from("users")
    .select("role")
    .eq("email", email)
    .maybeSingle();

  if (error) {
    console.error(`[Admin Check] DB role lookup failed for ${email}:`, error.message);
    return "user";
  }

  if (!data) {
    console.log(`[Admin Check] No users row found for ${email} — role=user`);
    return "user";
  }

  return (data.role as string) ?? "user";
}

export const config = {
  matcher: ["/dashboard/:path*", "/login"],
};
