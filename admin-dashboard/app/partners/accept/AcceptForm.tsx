"use client";

import { useActionState, useState } from "react";
import { PasswordField } from "@/components/PasswordInputs";
import { acceptPartnerInvite, type FormState } from "../actions";

export default function AcceptForm({ token, email }: { token: string; email: string }) {
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  // Signed in: navigate in the same callback, through middleware (see
  // FormState in ../actions). Not in an effect: setting the session cookie
  // re-renders this page at once, and on /accept the form is gone by then.
  const [state, action, pending] = useActionState<FormState, FormData>(async (prev, form) => {
    const result = await acceptPartnerInvite(prev, form);
    if (result.done) window.location.assign("/");
    return result;
  }, {});
  return (
    <form action={action} className="space-y-5">
      <input type="hidden" name="token" value={token} />
      {/* For password managers: the account this password belongs to. */}
      <input type="email" name="username" autoComplete="username" value={email} readOnly hidden />
      {state.error && (
        <div role="alert" className="rounded-lg border border-critical-200 bg-critical-50 px-3.5 py-3 text-[13px] leading-snug text-critical-700">
          {state.error}
        </div>
      )}
      <PasswordField label="Choose a password" name="password" value={password} onChange={setPassword} autoComplete="new-password">
        <p className="mt-1.5 text-xs text-gray-400">At least 8 characters, and not only numbers.</p>
      </PasswordField>
      <PasswordField label="Confirm password" name="confirm" value={confirm} onChange={setConfirm} autoComplete="new-password" />
      <button type="submit" className="btn-primary w-full" disabled={pending || state.done}>
        {pending || state.done ? "Setting up your account…" : "Create my partner account"}
      </button>
    </form>
  );
}
