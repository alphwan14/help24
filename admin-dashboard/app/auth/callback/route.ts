import { NextResponse, type NextRequest } from "next/server";
import { cookies } from "next/headers";
import { isAuthPKCECodeVerifierMissingError } from "@supabase/supabase-js";
import { createSessionWriter } from "@/lib/supabase-server";
import { resolveAdminAccess } from "@/lib/admin-identity";
import { RECOVERY_CONTINUE_PATH, RESET_PASSWORD_PATH, type RecoveryLinkError } from "@/lib/recovery-session";
import { GOOGLE_FLOW_COOKIE, googleReturnError, isOAuthSession } from "@/lib/google-sign-in";
import { DASHBOARD_HOME } from "@/lib/routes";

export const dynamic = "force-dynamic";

/** The sign-in page's `?error=` for each way the admin gate refuses a Google session. */
const GOOGLE_DENIAL = { unlinked: "not-linked", not_admin: "google-not-admin", unavailable: "unavailable" } as const;

/**
 * GET /auth/callback — where a password-reset link and "Continue with Google"
 * both land.
 *
 * Password reset:
 * 1. No query — the email's own link (supabase-auth-emails, recovery), which
 *    is Help24's address with the token after the `#`, so the email never
 *    shows the provider's. The browser keeps the `#` part across a redirect
 *    and never sends it to a server; /auth/continue reads it and hands it to
 *    Supabase's verify endpoint, which checks it as before.
 * 2. `?code=…` — Supabase sends the browser back with a one-time code.
 *    Exchanging it — with the PKCE verifier this browser stored when the email
 *    was requested — creates a recovery session, written to the same cookies
 *    the rest of the dashboard reads. Then on to /reset-password, with the
 *    code gone from the address bar and from history.
 *
 * Google: the same `?code=…` exchange. The session it produces says it came
 * from OAuth (`amr`), and then the ADMIN GATE IS ASKED HERE, before anything
 * else: a Google account that is not a linked Help24 admin is signed straight
 * back out and returned to the sign-in page with the reason. Only an admin's
 * Google sign-in reaches the dashboard, where middleware asks the same
 * question again on every request. With public sign-ups off in Supabase (as
 * they must be), a Google address with no dashboard login never even becomes
 * a login: GoTrue refuses it with `signup_disabled`.
 *
 * Supabase also documents a `token_hash` link verified here with `verifyOtp`;
 * it is deliberately not taken, because it would let a link be completed in a
 * browser that never asked for it.
 *
 * Public by construction: middleware does not match /auth/*, and the code is
 * worthless without the verifier cookie, which only the browser that asked has.
 * The landing paths are fixed, so there is nothing here to redirect elsewhere.
 */
export async function GET(request: NextRequest) {
  const params = request.nextUrl.searchParams;
  const code = params.get("code");

  // The email's own link: no query at all, the token after the `#`, which the
  // browser keeps across this redirect and never sends here.
  if (request.nextUrl.search === "") {
    return NextResponse.redirect(new URL(RECOVERY_CONTINUE_PATH, request.url));
  }

  const store = await cookies();
  const viaGoogle = store.get(GOOGLE_FLOW_COOKIE)?.value === "1";
  if (viaGoogle) store.delete(GOOGLE_FLOW_COOKIE);
  const toLogin = (error: string | null) => {
    const target = new URL("/login", request.url);
    if (error) target.searchParams.set("error", error);
    return NextResponse.redirect(target);
  };

  if (!code) {
    // Supabase (or Google, through it) refused before issuing a code.
    if (viaGoogle) return toLogin(googleReturnError(params));
    return NextResponse.redirect(new URL(`${RESET_PASSWORD_PATH}?error=link-invalid`, request.url));
  }

  const supabase = await createSessionWriter();
  const { data, error } = await supabase.auth.exchangeCodeForSession(code);
  if (error || !data.session) {
    if (viaGoogle) return toLogin("google-failed");
    const problem: RecoveryLinkError = isAuthPKCECodeVerifierMissingError(error) ? "other-browser" : "link-invalid";
    return NextResponse.redirect(new URL(`${RESET_PASSWORD_PATH}?error=${problem}`, request.url));
  }

  const { data: claims } = await supabase.auth.getClaims();
  if (!isOAuthSession(claims?.claims)) {
    return NextResponse.redirect(new URL(RESET_PASSWORD_PATH, request.url));
  }

  // A Google session: is this a Help24 admin? Same gate as middleware.
  const access = await resolveAdminAccess(data.session.user.id);
  if (!access.ok) {
    console.log(`[Admin Check] Google sign-in DENIED for subject ${data.session.user.id} (${access.reason})`);
    // This browser only; the person's other sessions (a partner's portal, say) are theirs.
    await supabase.auth.signOut({ scope: "local" });
    return toLogin(GOOGLE_DENIAL[access.reason]);
  }
  return NextResponse.redirect(new URL(DASHBOARD_HOME, request.url));
}
