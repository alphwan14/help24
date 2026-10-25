"use client";

import { useId, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createReauthClient, getSupabaseBrowser } from "@/lib/supabase-browser";
import { restoreArbitration } from "@/lib/arbitration-client";
import {
  FIELD_ORDER,
  changeOwnPassword,
  hasErrors,
  passwordRequirements,
  validatePasswordChange,
  type FieldErrors,
  type PasswordChangeInput,
  type PasswordField as Field,
} from "@/lib/admin-password";
import {
  PasswordChecklist,
  PasswordField,
  PasswordStrengthMeter,
} from "@/components/PasswordInputs";

const EMPTY: PasswordChangeInput = { currentPassword: "", newPassword: "", confirmPassword: "" };

type Notice = {
  tone: "success" | "error";
  text: string;
  /** Offer a way back in, with the sign-in page's matching message. */
  signIn?: "session-expired" | "password-updated";
};

/**
 * Change the signed-in admin's own password. The flow, and why it is safe,
 * is in lib/admin-password.ts → changeOwnPassword. The passwords go from this
 * form to Supabase Auth and nowhere else: no Help24 server sees them.
 */
export default function ChangePasswordForm({ email }: { email: string }) {
  const router = useRouter();
  const hintId = useId();
  const [values, setValues] = useState<PasswordChangeInput>(EMPTY);
  const [errors, setErrors] = useState<FieldErrors>({});
  const [notice, setNotice] = useState<Notice | null>(null);
  const [pending, setPending] = useState(false);
  // Bumped after a change so the fields remount: values gone, every
  // show/hide toggle back to hidden.
  const [generation, setGeneration] = useState(0);
  const refs: Record<Field, React.RefObject<HTMLInputElement | null>> = {
    currentPassword: useRef<HTMLInputElement>(null),
    newPassword: useRef<HTMLInputElement>(null),
    confirmPassword: useRef<HTMLInputElement>(null),
  };

  function update(field: Field, value: string) {
    setValues((v) => ({ ...v, [field]: value }));
    if (errors[field]) setErrors((e) => ({ ...e, [field]: undefined }));
  }

  function showErrors(next: FieldErrors) {
    setErrors(next);
    const first = FIELD_ORDER.find((f) => next[f]);
    // After the commit, so the field is enabled again and its message exists
    // for a screen reader to read out with it.
    if (first) requestAnimationFrame(() => refs[first].current?.focus());
  }

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (pending) return;
    setNotice(null);

    const invalid = validatePasswordChange(values);
    if (hasErrors(invalid)) {
      showErrors(invalid);
      return;
    }
    setErrors({});
    setPending(true);

    const outcome = await changeOwnPassword(
      getSupabaseBrowser().auth,
      () => createReauthClient().auth,
      values,
    );

    if (!outcome.ok) {
      setPending(false);
      if (outcome.reason === "wrong_current_password") {
        setValues((v) => ({ ...v, currentPassword: "" }));
      }
      if (outcome.fieldErrors) showErrors(outcome.fieldErrors);
      if (outcome.message) {
        setNotice({
          tone: "error",
          text: outcome.message,
          signIn:
            outcome.reason === "session_expired" || outcome.reason === "reauth_required"
              ? "session-expired"
              : undefined,
        });
      }
      return;
    }

    // Nothing sensitive outlives the change.
    setValues(EMPTY);
    setGeneration((g) => g + 1);

    if (!outcome.sessionKept) {
      setPending(false);
      setNotice({
        tone: "success",
        text: "Password changed. Sign in again with your new password to continue.",
        signIn: "password-updated",
      });
      return;
    }

    setNotice({
      tone: "success",
      text: "Password changed. Any other device signed in to this account has been signed out.",
    });
    // The arbitration token is the other half of a dashboard session (see
    // Sidebar → handleSignOut). Re-minting it retires the one any other
    // device still held. Best effort: the password has changed regardless.
    await restoreArbitration(true);
    setPending(false);
    router.refresh();
  }

  const confirmMatches =
    values.confirmPassword.length > 0 && values.confirmPassword === values.newPassword;

  return (
    <form onSubmit={onSubmit} noValidate className="mt-5 max-w-md space-y-4">
      {/* Password managers file the new password under the account this names. */}
      <input type="text" name="username" autoComplete="username" value={email} readOnly hidden />

      <fieldset key={generation} disabled={pending} className="space-y-4">
        <legend className="sr-only">Change your password</legend>
        <PasswordField
          ref={refs.currentPassword}
          label="Current password"
          name="current-password"
          autoComplete="current-password"
          value={values.currentPassword}
          onChange={(v) => update("currentPassword", v)}
          error={errors.currentPassword}
        />
        <PasswordField
          ref={refs.newPassword}
          label="New password"
          name="new-password"
          autoComplete="new-password"
          value={values.newPassword}
          onChange={(v) => update("newPassword", v)}
          error={errors.newPassword}
          describedBy={`${hintId}-strength ${hintId}-rules`}
        >
          <PasswordStrengthMeter id={`${hintId}-strength`} password={values.newPassword} />
          <PasswordChecklist
            id={`${hintId}-rules`}
            items={passwordRequirements(values.newPassword, values.currentPassword)}
          />
        </PasswordField>
        <PasswordField
          ref={refs.confirmPassword}
          label="Confirm new password"
          name="confirm-password"
          autoComplete="new-password"
          value={values.confirmPassword}
          onChange={(v) => update("confirmPassword", v)}
          error={errors.confirmPassword}
          describedBy={confirmMatches ? `${hintId}-match` : undefined}
        >
          {confirmMatches && !errors.confirmPassword && (
            <p id={`${hintId}-match`} className="mt-1.5 text-xs text-green-700">
              ✓ Passwords match
            </p>
          )}
        </PasswordField>
      </fieldset>

      <div aria-live="polite" aria-atomic="true">
        {notice?.tone === "success" && (
          <div className="flex gap-2 rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-700">
            <span aria-hidden>✓</span>
            <p>
              {notice.text}{" "}
              {notice.signIn && (
                <Link href={`/login?message=${notice.signIn}`} className="font-semibold underline">
                  Sign in
                </Link>
              )}
            </p>
          </div>
        )}
      </div>
      {notice?.tone === "error" && (
        <div role="alert" className="flex gap-2 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700">
          <span aria-hidden>✕</span>
          <p>
            {notice.text}{" "}
            {notice.signIn && (
              <Link href={`/login?message=${notice.signIn}`} className="font-semibold underline">
                Sign in again
              </Link>
            )}
          </p>
        </div>
      )}

      <button type="submit" disabled={pending} className="btn-primary w-full sm:w-auto">
        {pending ? "Changing password…" : "Change password"}
      </button>
    </form>
  );
}
