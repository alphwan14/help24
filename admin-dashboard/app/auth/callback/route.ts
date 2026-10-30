import { NextResponse, type NextRequest } from "next/server";
import { isAuthPKCECodeVerifierMissingError } from "@supabase/supabase-js";
import { createSessionWriter } from "@/lib/supabase-server";
import { RECOVERY_CONTINUE_PATH, RESET_PASSWORD_PATH, type RecoveryLinkError } from "@/lib/recovery-session";

export const dynamic = "force-dynamic";

/**
 * GET /auth/callback — where a password-reset link lands, twice.
 *
 * 1. No query — the email's own link (supabase-auth-emails, recovery), which
 *    is Help24's address with the token after the `#`, so the email never
 *    shows the provider's. The browser keeps the `#` part across a redirect
 *    and never sends it to a server; /auth/continue reads it and hands it to
 *    Supabase's verify endpoint, which checks it as before.
 * 2. `?code=…` — Supabase sends the browser back with a one-time code.
 * Exchanging it — with the PKCE verifier this browser stored when the email was
 * requested — creates a recovery session, written to the same cookies the rest
 * of the dashboard reads. Then on to /reset-password, with the code gone from
 * the address bar and from history.
 *
 * Supabase also documents a `token_hash` link verified here with `verifyOtp`;
 * it is deliberately not taken, because it would let a link be completed in a
 * browser that never asked for it.
 *
 * Public by construction: middleware does not match /auth/*, and the code is
 * worthless without the verifier cookie, which only the browser that asked has.
 * The landing path is fixed, so there is nothing here to redirect elsewhere.
 */
export async function GET(request: NextRequest) {
  const code = request.nextUrl.searchParams.get("code");

  // The email's own link: no query at all, the token after the `#`, which the
  // browser keeps across this redirect and never sends here.
  if (request.nextUrl.search === "") {
    return NextResponse.redirect(new URL(RECOVERY_CONTINUE_PATH, request.url));
  }

  let problem: RecoveryLinkError | null = "link-invalid";
  if (code) {
    const supabase = await createSessionWriter();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) problem = null;
    else if (isAuthPKCECodeVerifierMissingError(error)) problem = "other-browser";
  }
  // No code: Supabase itself refused the link (`?error=access_denied&error_code=otp_expired`).

  const target = new URL(RESET_PASSWORD_PATH, request.url);
  if (problem) target.searchParams.set("error", problem);
  return NextResponse.redirect(target);
}
