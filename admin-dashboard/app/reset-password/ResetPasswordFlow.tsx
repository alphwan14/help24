"use client";

import { useEffect, useId, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import { restoreArbitration } from "@/lib/arbitration-client";
import {
  hasErrors,
  passwordRequirements,
  resetOwnPassword,
  validatePasswordReset,
  type FieldErrors,
  type PasswordResetInput,
} from "@/lib/admin-password";
import {
  classifyRecoverySession,
  type RecoveryLinkError,
  type RecoveryState,
} from "@/lib/recovery-session";
import {
  PasswordChecklist,
  PasswordField,
  PasswordStrengthMeter,
} from "@/components/PasswordInputs";

type View = "checking" | RecoveryState | "done";

const EMPTY: PasswordResetInput = { newPassword: "", confirmPassword: "" };

/**
 * The reset screen. Which version a person sees depends only on the session
 * the browser holds — classified from its verified claims, the way the
 * provider itself classifies it (lib/recovery-session.ts):
 *
 *   recovery  → choose a new password (no current one asked: the link proved
 *               the inbox, which is exactly what the provider accepts)
 *   signed-in → an ordinary session; send them to Settings, which asks for
 *               the current password — this page is not a way around that
 *   none      → the link failed; say why, and offer a new one
 */
export default function ResetPasswordFlow({ linkError }: { linkError: RecoveryLinkError | null }) {
  const router = useRouter();
  const hintId = useId();
  const [view, setView] = useState<View>("checking");
  const [expired, setExpired] = useState(false);
  const [email, setEmail] = useState("");
  const [values, setValues] = useState<PasswordResetInput>(EMPTY);
  const [errors, setErrors] = useState<FieldErrors>({});
  const [message, setMessage] = useState<string | null>(null);
  const [pending, setPending] = useState(false);
  const newRef = useRef<HTMLInputElement>(null);
  const confirmRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      let claims: unknown = null;
      try {
        const { data } = await getSupabaseBrowser().auth.getClaims();
        claims = data?.claims ?? null;
      } catch {
        claims = null;
      }
      if (cancelled) return;
      const claimedEmail = (claims as { email?: unknown } | null)?.email;
      setEmail(typeof claimedEmail === "string" ? claimedEmail : "");
      setView(classifyRecoverySession(claims, Date.now() / 1000));
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  function update(field: keyof PasswordResetInput, value: string) {
    setValues((v) => ({ ...v, [field]: value }));
    if (errors[field]) setErrors((e) => ({ ...e, [field]: undefined }));
  }

  function showErrors(next: FieldErrors) {
    setErrors(next);
    const target = next.newPassword ? newRef : next.confirmPassword ? confirmRef : null;
    if (target) requestAnimationFrame(() => target.current?.focus());
  }

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (pending) return;
    setMessage(null);

    const invalid = validatePasswordReset(values);
    if (hasErrors(invalid)) {
      showErrors(invalid);
      return;
    }
    setErrors({});
    setPending(true);

    const outcome = await resetOwnPassword(getSupabaseBrowser().auth, values);

    if (!outcome.ok) {
      setPending(false);
      if (outcome.reason === "session_expired") {
        setValues(EMPTY);
        setExpired(true);
        setView("none");
        return;
      }
      if (outcome.fieldErrors) showErrors(outcome.fieldErrors);
      if (outcome.message) setMessage(outcome.message);
      return;
    }

    setValues(EMPTY);
    setView("done");
    // A forgotten password is also how a stolen one gets fixed, so retire the
    // arbitration token any other device held, as Settings does. Best effort.
    await restoreArbitration(true);
    router.replace("/dashboard");
    router.refresh();
  }

  if (view === "checking" || view === "done") {
    return (
      <div className="card p-8 text-center space-y-4" aria-live="polite">
        <div className="mx-auto w-11 h-11 rounded-full border-2 border-brand-200 border-t-brand-600 animate-spin" />
        {view === "done" ? (
          <div>
            <h2 className="text-lg font-bold text-gray-900">Password updated</h2>
            <p className="text-sm text-gray-500 mt-1">Taking you to the dashboard…</p>
          </div>
        ) : (
          <p className="text-sm text-gray-500">Checking your reset link…</p>
        )}
      </div>
    );
  }

  if (view === "none") {
    const otherBrowser = linkError === "other-browser" && !expired;
    return (
      <div className="card p-6 text-center space-y-3">
        <div className="mx-auto w-10 h-10 rounded-full bg-red-50 border border-red-200 flex items-center justify-center text-red-600">
          ✕
        </div>
        <h2 className="text-base font-bold text-gray-900">
          {otherBrowser ? "Open the link in the browser that asked for it" : "This reset link has expired"}
        </h2>
        <p className="text-sm text-gray-700">
          {otherBrowser
            ? "For your security, a reset link only works in the browser it was requested from. Request a new one here, or open the email on the device you used."
            : "Reset links work once and only for a limited time. Request a new one and use it soon."}
        </p>
        <Link href="/login?reset=1" className="btn-primary w-full">
          Request a new link
        </Link>
        <Link href="/login" className="inline-block text-sm text-gray-500 hover:text-gray-700">
          Back to sign in
        </Link>
      </div>
    );
  }

  if (view === "signed-in") {
    return (
      <div className="card p-6 text-center space-y-3">
        <h2 className="text-base font-bold text-gray-900">You&apos;re already signed in</h2>
        <p className="text-sm text-gray-700">
          Change your password from Settings, where you&apos;ll confirm the current one. If
          you&apos;ve forgotten it, you can email yourself a fresh reset link from there.
        </p>
        <Link href="/dashboard/settings" className="btn-primary w-full">
          Go to Settings
        </Link>
      </div>
    );
  }

  return (
    <div className="card p-6 space-y-4">
      <div>
        <h2 className="text-base font-bold text-gray-900">Set a new password</h2>
        {email && (
          <p className="text-sm text-gray-500 mt-0.5">
            For <span className="font-medium text-gray-700">{email}</span>
          </p>
        )}
      </div>

      <form onSubmit={onSubmit} noValidate className="space-y-4">
        <input type="text" name="username" autoComplete="username" value={email} readOnly hidden />
        <fieldset disabled={pending} className="space-y-4">
          <legend className="sr-only">Choose a new password</legend>
          <PasswordField
            ref={newRef}
            label="New password"
            name="new-password"
            autoComplete="new-password"
            value={values.newPassword}
            onChange={(v) => update("newPassword", v)}
            error={errors.newPassword}
            describedBy={`${hintId}-strength ${hintId}-rules`}
          >
            <PasswordStrengthMeter id={`${hintId}-strength`} password={values.newPassword} />
            <PasswordChecklist id={`${hintId}-rules`} items={passwordRequirements(values.newPassword)} />
          </PasswordField>
          <PasswordField
            ref={confirmRef}
            label="Confirm new password"
            name="confirm-password"
            autoComplete="new-password"
            value={values.confirmPassword}
            onChange={(v) => update("confirmPassword", v)}
            error={errors.confirmPassword}
          />
        </fieldset>

        {message && (
          <div role="alert" className="p-3 rounded-lg bg-red-50 border border-red-200 text-red-700 text-sm flex gap-2">
            <span aria-hidden>✕</span>
            <span>{message}</span>
          </div>
        )}

        <button type="submit" disabled={pending} className="btn-primary w-full">
          {pending ? "Saving…" : "Save new password"}
        </button>
      </form>
    </div>
  );
}
