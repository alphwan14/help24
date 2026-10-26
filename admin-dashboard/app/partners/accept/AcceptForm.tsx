"use client";

import { useActionState } from "react";
import { acceptPartnerInvite, type FormState } from "../actions";

export default function AcceptForm({ token, email }: { token: string; email: string }) {
  // Signed in: navigate in the same callback, through middleware (see
  // FormState in ../actions). Not in an effect: setting the session cookie
  // re-renders this page at once, and on /accept the form is gone by then.
  const [state, action, pending] = useActionState<FormState, FormData>(async (prev, form) => {
    const result = await acceptPartnerInvite(prev, form);
    if (result.done) window.location.assign("/");
    return result;
  }, {});
  return (
    <form action={action} className="mt-6 space-y-3">
      <input type="hidden" name="token" value={token} />
      {/* For password managers: the account this password belongs to. */}
      <input type="email" name="username" autoComplete="username" value={email} readOnly hidden />
      <label className="block">
        <span className="text-xs font-semibold text-gray-600">Password</span>
        <input name="password" type="password" autoComplete="new-password" minLength={8} required className="input mt-1" />
        <span className="block text-[11.5px] text-gray-400 mt-1">At least 8 characters — not only numbers.</span>
      </label>
      <label className="block">
        <span className="text-xs font-semibold text-gray-600">Confirm password</span>
        <input name="confirm" type="password" autoComplete="new-password" required className="input mt-1" />
      </label>
      {state.error && <p role="alert" className="text-[13px] text-critical-700">{state.error}</p>}
      <button type="submit" className="btn-primary w-full" disabled={pending || state.done}>
        {pending ? "Setting up…" : "Create my partner account"}
      </button>
    </form>
  );
}
