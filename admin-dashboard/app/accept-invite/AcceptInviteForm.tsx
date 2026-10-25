"use client";

import { useEffect, useRef, useState } from "react";
import type { AdminRole } from "@/lib/api";

const ROLE_LABELS: Record<AdminRole, string> = {
  support_agent: "Support Agent",
  senior_admin: "Senior Admin",
  super_admin: "Super Admin",
};

/**
 * The invitation form. It is a plain POST to /accept-invite/submit, which runs
 * the whole hand-off on the server — account, session, arbitration — and
 * answers with a redirect: the dashboard, the sign-in page, or back here with
 * an error. lib/invite-acceptance.ts has the story of why it is not a Server
 * Action, and of the client-side sign-in this component used to attempt.
 */
export default function AcceptInviteForm({
  token,
  email,
  emailSignature,
  role,
  expiresAt,
  error,
}: {
  token: string;
  email: string;
  /** The server's signature over (token, email) — lib/invite-email-binding.ts. */
  emailSignature: string;
  role: AdminRole;
  expiresAt: string;
  /** A message chosen by the page from a fixed list, never text from the URL. */
  error: string | null;
}) {
  const [showPassword, setShowPassword] = useState(false);
  const [submitting, setSubmitting] = useState(false);

  // One submission per page load. A double-click or a double Enter must not
  // post twice; the server would cope, but there is nothing to gain.
  const sent = useRef(false);
  function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    if (sent.current) {
      e.preventDefault();
      return;
    }
    sent.current = true;
    setSubmitting(true);
  }
  // Back from the next page, the browser may restore this one as it was left.
  useEffect(() => {
    function reset(e: PageTransitionEvent) {
      if (!e.persisted) return;
      sent.current = false;
      setSubmitting(false);
    }
    window.addEventListener("pageshow", reset);
    return () => window.removeEventListener("pageshow", reset);
  }, []);

  return (
    <div className="card p-6 space-y-4">
      <div>
        <div className="flex items-center gap-2 mb-1">
          <span className="badge bg-green-100 text-green-700">✓ Valid invitation</span>
        </div>
        <p className="text-sm text-gray-500">You&apos;ve been invited to join as</p>
        <p className="font-semibold text-gray-900">{email}</p>
        <span className="badge bg-indigo-100 text-indigo-700 mt-1 inline-block">
          {ROLE_LABELS[role] ?? role}
        </span>
      </div>

      <form method="post" action="/accept-invite/submit" onSubmit={onSubmit} className="space-y-4">
        <input type="hidden" name="token" value={token} />
        {/* Names the account for password managers, and lets a retry of an
            acceptance that already went through sign straight in. */}
        <input type="email" name="email" autoComplete="username" value={email} readOnly hidden />
        <input type="hidden" name="email_sig" value={emailSignature} />

        {error && (
          <div role="alert" className="p-3 rounded-lg bg-red-50 border border-red-200 text-red-700 text-sm flex gap-2">
            <span aria-hidden>✕</span>
            <span>{error}</span>
          </div>
        )}

        <div>
          <label htmlFor="invite-name" className="block text-sm font-medium text-gray-700 mb-1">
            Full name
          </label>
          <input id="invite-name" name="name" type="text" className="input" placeholder="Jane Doe" required minLength={2} autoComplete="name" />
        </div>

        <div>
          <label htmlFor="invite-password" className="block text-sm font-medium text-gray-700 mb-1">
            Create password
          </label>
          <div className="relative">
            <input
              id="invite-password"
              name="password"
              type={showPassword ? "text" : "password"}
              className="input pr-16"
              placeholder="Min 8 characters"
              required
              minLength={8}
              autoComplete="new-password"
            />
            <button
              type="button"
              onClick={() => setShowPassword((s) => !s)}
              aria-label={showPassword ? "Hide passwords" : "Show passwords"}
              aria-pressed={showPassword}
              className="absolute inset-y-0 right-0 flex items-center px-3 text-xs text-gray-400 hover:text-gray-600"
            >
              {showPassword ? "Hide" : "Show"}
            </button>
          </div>
        </div>

        <div>
          <label htmlFor="invite-confirm" className="block text-sm font-medium text-gray-700 mb-1">
            Confirm password
          </label>
          <input
            id="invite-confirm"
            name="confirm"
            type={showPassword ? "text" : "password"}
            className="input"
            placeholder="Re-enter password"
            required
            minLength={8}
            autoComplete="new-password"
          />
        </div>

        <button type="submit" disabled={submitting} className="btn-primary w-full">
          {submitting ? "Setting up your account…" : "Accept invitation"}
        </button>
        {submitting && (
          <p className="text-center text-xs text-gray-400" aria-live="polite">
            Creating your account and signing you in — this is safe to wait on.
          </p>
        )}
      </form>

      <p className="text-xs text-gray-400 text-center">
        Invitation valid until {new Date(expiresAt).toLocaleDateString("en-KE", {
          day: "2-digit",
          month: "short",
          year: "numeric",
        })}
      </p>
    </div>
  );
}
