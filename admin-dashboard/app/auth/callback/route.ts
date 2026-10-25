import { NextResponse, type NextRequest } from "next/server";
import { isAuthPKCECodeVerifierMissingError } from "@supabase/supabase-js";
import { createSessionWriter } from "@/lib/supabase-server";
import { RESET_PASSWORD_PATH, type RecoveryLinkError } from "@/lib/recovery-session";

export const dynamic = "force-dynamic";

/**
 * GET /auth/callback — where a Supabase password-reset link lands.
 *
 * The email's link is Supabase's own `{{ .ConfirmationURL }}`: Supabase checks
 * the one-time token itself and sends the browser here with a one-time `code`.
 * Exchanging it — with the PKCE verifier this browser stored when the email was
 * requested — creates a recovery session, written to the same cookies the rest
 * of the dashboard reads. Then on to /reset-password, with the code gone from
 * the address bar and from history.
 *
 * This is the only shape accepted. Supabase also documents a `token_hash` link
 * verified with `verifyOtp`; it is deliberately not taken here, because it
 * would let a link be completed in a browser that never asked for it, and the
 * shipped templates (admin-dashboard/supabase-auth-emails) never produce one.
 *
 * Public by construction: middleware does not match /auth/*, and the code is
 * worthless without the verifier cookie, which only the browser that asked has.
 * The landing path is fixed, so there is nothing here to redirect elsewhere.
 */
export async function GET(request: NextRequest) {
  const code = request.nextUrl.searchParams.get("code");

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
