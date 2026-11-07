"use client";

import { useActionState, useState } from "react";
import AuthShell from "@/components/auth/AuthShell";
import { SIGN_IN_HELP } from "@/lib/auth-audiences";
import { PasswordField } from "@/components/PasswordInputs";
import {
  requestPartnerPasswordReset,
  signInPartner,
  type FormState,
  type ResetState,
} from "../actions";

const ALERT = "rounded-lg border border-critical-200 bg-critical-50 px-3.5 py-3 text-[13px] leading-snug text-critical-700";

/**
 * The partner sign-in page, and its "Forgot password?" mode. The page frame
 * is drawn here so the heading follows the mode.
 */
export default function LoginForm({ notice, startInReset = false }: { notice?: string; startInReset?: boolean }) {
  const [resetMode, setResetMode] = useState(startInReset);
  return (
    <AuthShell
      product="Help24 Partners"
      notice="Partner access is by invitation"
      help={SIGN_IN_HELP}
      title={resetMode ? "Reset your password" : "Sign in"}
      subtitle={resetMode ? "We'll email you a link to choose a new one." : undefined}
      below={resetMode ? undefined : <p>New to Help24 Partners? Open the invitation Help24 sent you.</p>}
    >
      {resetMode ? (
        <ResetForm onBack={() => setResetMode(false)} />
      ) : (
        <SignInForm notice={notice} onForgot={() => setResetMode(true)} />
      )}
    </AuthShell>
  );
}

function SignInForm({ notice, onForgot }: { notice?: string; onForgot: () => void }) {
  const [password, setPassword] = useState("");
  // Signed in: navigate in the same callback, through middleware (see
  // FormState in ../actions). Not in an effect: setting the session cookie
  // re-renders this page at once, and on /accept the form is gone by then.
  const [state, action, pending] = useActionState<FormState, FormData>(async (prev, form) => {
    const result = await signInPartner(prev, form);
    if (result.done) window.location.assign("/");
    return result;
  }, {});
  const error = state.error ?? notice;
  return (
    <form action={action} className="space-y-5">
      {error && (
        <div role="alert" className={ALERT}>
          {error}
        </div>
      )}
      <div>
        <label htmlFor="partner-email" className="block text-sm font-medium text-gray-700 mb-1">
          Email address
        </label>
        <input
          id="partner-email"
          name="email"
          type="email"
          autoComplete="username"
          inputMode="email"
          required
          defaultValue={state.email}
          placeholder="you@example.com"
          className="input"
        />
      </div>
      <div>
        <PasswordField label="Password" name="password" value={password} onChange={setPassword} autoComplete="current-password" />
        <div className="mt-1.5 text-right">
          <button
            type="button"
            onClick={onForgot}
            className="text-[13px] font-medium text-gray-500 hover:text-gray-900 hover:underline"
          >
            Forgot password?
          </button>
        </div>
      </div>
      <button type="submit" className="btn-primary w-full" disabled={pending || state.done}>
        {pending || state.done ? "Signing in…" : "Sign in"}
      </button>
    </form>
  );
}

/**
 * The server decides whether the address gets an email and answers every
 * address the same way (app/partners/actions.ts), so this form never learns
 * which it was — and neither does anyone watching it.
 */
function ResetForm({ onBack }: { onBack: () => void }) {
  const [state, action, pending] = useActionState<ResetState, FormData>(requestPartnerPasswordReset, {});
  return (
    <form action={action} className="space-y-5">
      {state.sent && (
        <div role="status" className="rounded-lg border border-info-200 bg-info-50 px-3.5 py-3 text-[13px] leading-snug text-info-700">
          Check your inbox. We&apos;ve sent a reset link to {state.sent} — open it on this device, in this browser.
          Nothing after a few minutes? Make sure this is the address Help24 invited you with, or ask Help24 for a new
          invitation.
        </div>
      )}
      {state.error && (
        <div role="alert" className={ALERT}>
          {state.error}
        </div>
      )}
      <div>
        <label htmlFor="partner-reset-email" className="block text-sm font-medium text-gray-700 mb-1">
          Email address
        </label>
        <input
          id="partner-reset-email"
          name="email"
          type="email"
          autoComplete="username"
          inputMode="email"
          required
          placeholder="you@example.com"
          className="input"
        />
      </div>
      <button type="submit" className="btn-primary w-full" disabled={pending || Boolean(state.sent)}>
        {pending ? "Sending…" : "Send reset link"}
      </button>
      <button
        type="button"
        onClick={onBack}
        className="w-full text-center text-[13px] font-medium text-gray-500 hover:text-gray-900"
      >
        ← Back to sign in
      </button>
    </form>
  );
}
