import { NextResponse, type NextRequest } from "next/server";
import { createServiceClient } from "@/lib/supabase-server";
import { recoveryRedirectUrl } from "@/lib/recovery-session";
import { plausibleEmail, sendResetUniformly, tooManyResetRequests } from "@/lib/password-reset";

export const dynamic = "force-dynamic";

/**
 * POST /api/admin/password-reset { email } → { ok: true }
 *
 * "Forgot password" for the admin console. The SERVER decides whether the
 * address gets an email — only an active admin_users row does — and the
 * caller can never tell which way it went: every valid address gets the same
 * body, the same cookie and, give or take the padding, the same timing (see
 * lib/password-reset.ts, shared with the partner portal).
 *
 * The link still only works in this browser: the verifier cookie set here is
 * the one /auth/callback exchanges the code with.
 */
export async function POST(request: NextRequest) {
  const started = Date.now();
  const body = (await request.json().catch(() => null)) as { email?: unknown } | null;
  const email = plausibleEmail(body?.email);
  if (!email) return NextResponse.json({ message: "Enter a valid email address." }, { status: 400 });

  const ip = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || "unknown";
  if (tooManyResetRequests(`admin:${ip}`, started)) {
    return NextResponse.json({ message: "Too many attempts. Wait a few minutes, then try again." }, { status: 429 });
  }

  const { data, error } = await createServiceClient()
    .from("admin_users")
    .select("id")
    .eq("email", email)
    .eq("active", true)
    .limit(1);
  if (error) {
    // Says nothing about the address: the lookup failed for everyone.
    console.error("[password-reset] admin lookup failed:", error.message);
    return NextResponse.json({ message: "We couldn't send the reset email just now. Try again." }, { status: 503 });
  }

  await sendResetUniformly({
    email,
    eligible: (data ?? []).length > 0,
    redirectTo: recoveryRedirectUrl(request.nextUrl.origin),
    started,
  });
  return NextResponse.json({ ok: true }, { headers: { "Cache-Control": "no-store" } });
}
