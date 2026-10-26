"use client";

import { useActionState } from "react";
import { signInPartner, type FormState } from "../actions";

export default function LoginForm({ notice }: { notice?: string }) {
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
    <form action={action} className="mt-6 space-y-3">
      <label className="block">
        <span className="text-xs font-semibold text-gray-600">Email</span>
        <input name="email" type="email" autoComplete="username" required defaultValue={state.email} className="input mt-1" />
      </label>
      <label className="block">
        <span className="text-xs font-semibold text-gray-600">Password</span>
        <input name="password" type="password" autoComplete="current-password" required className="input mt-1" />
      </label>
      {error && <p role="alert" className="text-[13px] text-critical-700">{error}</p>}
      <button type="submit" className="btn-primary w-full" disabled={pending || state.done}>
        {pending ? "Signing in…" : "Sign in"}
      </button>
    </form>
  );
}
