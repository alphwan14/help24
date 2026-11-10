"use client";

import { useEffect, useId, useRef, useState } from "react";
import type { AdminRole } from "@/lib/api";
import { passwordProblem, passwordRequirements } from "@/lib/admin-password";
import { PasswordChecklist, PasswordField, PasswordStrengthMeter } from "@/components/PasswordInputs";

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
 *
 * The password boxes are the ones Settings and Reset password use: each with
 * its own show/hide, and under the new password the app's strength meter and
 * checklist (lib/admin-password.ts). The server checks the same rules again.
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
  const hintId = useId();
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [fieldErrors, setFieldErrors] = useState<{ password?: string; confirm?: string }>({});
  const [submitting, setSubmitting] = useState(false);

  // One submission per page load. A double-click or a double Enter must not
  // post twice; the server would cope, but there is nothing to gain.
  const sent = useRef(false);
  function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    if (sent.current) {
      e.preventDefault();
      return;
    }
    // Said here, beside the box, rather than after a round trip.
    const problem = passwordProblem(password);
    const mismatch = !problem && password !== confirm ? "Passwords do not match." : undefined;
    if (problem || mismatch) {
      e.preventDefault();
      setFieldErrors({ password: problem ?? undefined, confirm: mismatch });
      return;
    }
    setFieldErrors({});
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
    // AuthShell (the page) draws the card; this is its content.
    <div className="space-y-5">
      <div className="rounded-xl bg-surface-sunken px-4 py-3">
        <p className="text-xs font-medium text-positive-700">✓ Valid invitation</p>
        <p className="mt-1 break-all text-[15px] font-semibold text-gray-900">{email}</p>
        <p className="mt-0.5 text-[13px] text-gray-500">
          Joining as <span className="font-medium text-gray-700">{ROLE_LABELS[role] ?? role}</span>
        </p>
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

        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div>
            <label htmlFor="invite-first-name" className="block text-sm font-medium text-gray-700 mb-1">
              First name
            </label>
            <input
              id="invite-first-name"
              name="first_name"
              type="text"
              className="input"
              placeholder="Jane"
              required
              maxLength={60}
              autoComplete="given-name"
            />
          </div>
          <div>
            <label htmlFor="invite-last-name" className="block text-sm font-medium text-gray-700 mb-1">
              Last name
            </label>
            <input
              id="invite-last-name"
              name="last_name"
              type="text"
              className="input"
              placeholder="Doe"
              required
              maxLength={60}
              autoComplete="family-name"
            />
          </div>
        </div>

        <PasswordField
          label="Create password"
          name="password"
          autoComplete="new-password"
          value={password}
          onChange={(v) => {
            setPassword(v);
            if (fieldErrors.password) setFieldErrors((f) => ({ ...f, password: undefined }));
          }}
          error={fieldErrors.password}
          describedBy={`${hintId}-strength ${hintId}-rules`}
        >
          <PasswordStrengthMeter id={`${hintId}-strength`} password={password} />
          <PasswordChecklist id={`${hintId}-rules`} items={passwordRequirements(password)} />
        </PasswordField>

        <PasswordField
          label="Confirm password"
          name="confirm"
          autoComplete="new-password"
          value={confirm}
          onChange={(v) => {
            setConfirm(v);
            if (fieldErrors.confirm) setFieldErrors((f) => ({ ...f, confirm: undefined }));
          }}
          error={fieldErrors.confirm}
        />

        <button type="submit" disabled={submitting} className="btn-primary w-full">
          {submitting ? "Setting up your account…" : "Accept invitation"}
        </button>
        {submitting && (
          <p className="text-center text-xs text-gray-400" aria-live="polite">
            Creating your account and signing you in. This is safe to wait on.
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
