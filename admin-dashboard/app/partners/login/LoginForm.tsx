"use client";

import { useActionState, useState } from "react";
import { PasswordField } from "@/components/PasswordInputs";
import { signInPartner, type FormState } from "../actions";

export default function LoginForm({ notice }: { notice?: string }) {
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
        <div role="alert" className="rounded-lg border border-critical-200 bg-critical-50 px-3.5 py-3 text-[13px] leading-snug text-critical-700">
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
      <PasswordField label="Password" name="password" value={password} onChange={setPassword} autoComplete="current-password" />
      <button type="submit" className="btn-primary w-full" disabled={pending || state.done}>
        {pending || state.done ? "Signing in…" : "Sign in"}
      </button>
    </form>
  );
}
