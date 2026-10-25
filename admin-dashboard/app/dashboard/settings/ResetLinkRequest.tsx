"use client";

import { useState } from "react";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import { requestPasswordReset } from "@/lib/admin-password";
import { recoveryRedirectUrl } from "@/lib/recovery-session";

/**
 * "Forgot your current password?" for an admin who is signed in but cannot
 * prove the old one. Sends Supabase's own reset email to THIS session's address
 * — the email is a prop from the verified session, never typed — and the link
 * finishes at /reset-password (see lib/recovery-session.ts).
 *
 * It must be the browser's own client that asks: the PKCE verifier the link
 * needs is stored in this browser's cookies by the request.
 */
export default function ResetLinkRequest({
  email,
  heading,
  action,
}: {
  email: string;
  heading: string;
  action: string;
}) {
  const [state, setState] = useState<"idle" | "sending" | "sent">("idle");
  const [error, setError] = useState<string | null>(null);

  async function send() {
    setState("sending");
    setError(null);
    const result = await requestPasswordReset(
      getSupabaseBrowser().auth,
      email,
      recoveryRedirectUrl(window.location.origin),
    );
    if (result.ok) {
      setState("sent");
    } else {
      setError(result.message);
      setState("idle");
    }
  }

  return (
    <div className="mt-6 border-t border-gray-100 pt-5">
      <h3 className="text-sm font-semibold text-gray-900">{heading}</h3>
      <p className="mt-0.5 text-sm text-gray-500">
        We&apos;ll email a reset link to <span className="font-medium text-gray-700">{email}</span>.
        Open it in this browser — for your security it won&apos;t work anywhere else.
      </p>

      <div aria-live="polite" aria-atomic="true">
        {state === "sent" && (
          <p className="mt-3 rounded-lg border border-blue-200 bg-blue-50 p-3 text-sm text-blue-700">
            Reset link sent. Open it in this browser — and check your spam folder if it
            hasn&apos;t arrived in a few minutes. The link works once.
          </p>
        )}
      </div>
      {error && (
        <p role="alert" className="mt-3 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700">
          {error}
        </p>
      )}

      <button
        type="button"
        onClick={send}
        disabled={state !== "idle"}
        className="btn-ghost mt-3 border border-gray-200 disabled:opacity-60"
      >
        {state === "sending" ? "Sending…" : state === "sent" ? "Link sent" : action}
      </button>
    </div>
  );
}
