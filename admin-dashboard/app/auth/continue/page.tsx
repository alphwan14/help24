"use client";

import { useEffect } from "react";
import { RESET_PASSWORD_PATH, recoveryRedirectUrl } from "@/lib/recovery-session";

/** GoTrue's PKCE recovery token: `pkce_` + the hex token hash. */
const PKCE_TOKEN = /^pkce_[0-9a-f]{16,128}$/;

/**
 * /auth/continue — the reset email's link, read in the browser.
 *
 * The email links to Help24's own /auth/callback with the token after the `#`
 * (supabase-auth-emails, recovery), and the callback redirects here; the
 * browser keeps the `#` part across that redirect and never sends it to a
 * server, so the token reaches no Help24 server or log. This page hands it to
 * Supabase's verify endpoint — the same request the email used to make
 * directly — which checks it and returns to /auth/callback with a PKCE code.
 *
 * Only a PKCE token is passed on: the code it comes back with needs the
 * verifier this browser stored when the reset was asked for, so the link
 * still cannot be finished anywhere else. Anything else (an error Supabase put
 * after the `#`, a mangled link) is "this link can't be used".
 */
export default function ContinueRecovery() {
  useEffect(() => {
    const token = window.location.hash.slice(1);
    // Off the address bar and out of history before anything else happens.
    window.history.replaceState(null, "", window.location.pathname);

    if (!PKCE_TOKEN.test(token)) {
      window.location.replace(`${RESET_PASSWORD_PATH}?error=link-invalid`);
      return;
    }
    const verify = new URL("/auth/v1/verify", process.env.NEXT_PUBLIC_SUPABASE_URL);
    verify.searchParams.set("token", token);
    verify.searchParams.set("type", "recovery");
    verify.searchParams.set("redirect_to", recoveryRedirectUrl(window.location.origin));
    window.location.replace(verify.href);
  }, []);

  return (
    <div className="min-h-screen flex items-center justify-center bg-page p-4">
      <p className="text-sm text-gray-500">Opening your reset link…</p>
    </div>
  );
}
