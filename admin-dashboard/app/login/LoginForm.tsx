"use client";

import { useState, useEffect } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import { EyeIcon } from "@/components/PasswordInputs";
import { DASHBOARD_HOME } from "@/lib/routes";
import AuthShell from "@/components/auth/AuthShell";
import { SIGN_IN_HELP } from "@/lib/auth-audiences";
import GoogleButton, { type GoogleResult } from "@/components/auth/GoogleButton";

/** URL-param messages (set by middleware / redirects). */
const URL_MESSAGES: Record<string, { text: string; type: "info" | "error" }> = {
  unauthorized: {
    text: "Access denied — your account does not have admin privileges.",
    type: "error",
  },
  // Middleware (or the Google check) sends this when sign-in worked but the
  // login is not linked to a Help24 account. Saying "no privileges" here sent
  // one admin through repeated sign-ins and password resets that could never help.
  "not-linked": {
    text: "You signed in, but this login isn't connected to a Help24 account yet. A super admin has been alerted — once they link it, sign in here again. There's no need to reset your password.",
    type: "info",
  },
  // The Google account is not a Help24 admin login (refused by Supabase, or
  // by app/api/admin/google-check). The person has just proved they own it,
  // so saying so reveals nothing about anyone else.
  "google-not-admin": {
    text: "This Google account isn't a Help24 admin login. Continue with the Google account that uses your admin email, or sign in with your email and password.",
    type: "error",
  },
  "google-failed": {
    text: "Google sign-in didn't finish. Please try again, or sign in with your email and password.",
    type: "error",
  },
  unavailable: {
    text: "We couldn't check your access just now, so you weren't let in. Please try again in a moment.",
    type: "error",
  },
  disabled: {
    text: "This account has been disabled. Contact a system administrator.",
    type: "error",
  },
  "session-expired": {
    text: "Your session expired. Please sign in again.",
    type: "info",
  },
  "password-updated": {
    text: "Password updated. Sign in with your new password.",
    type: "info",
  },
  "invite-accepted": {
    text: "Welcome aboard! Your admin account is ready — sign in to continue.",
    type: "info",
  },
  // Accepting an invite creates the login; a super admin still links it to a
  // Help24 identity before the dashboard opens (see lib/invite-acceptance.ts).
  "invite-pending": {
    text: "Your password is set. A super admin still has to finish activating your account — once they have, sign in here with that password.",
    type: "info",
  },
};

/** Map raw Supabase auth errors to clean, user-facing copy. */
function friendlyAuthError(message: string): string {
  const m = message.toLowerCase();
  if (m.includes("invalid login") || m.includes("invalid credentials"))
    return "Invalid email or password.";
  if (m.includes("email not confirmed"))
    return "Your email is not confirmed yet. Check your inbox.";
  if (m.includes("banned") || m.includes("disabled"))
    return "This account has been disabled. Contact a system administrator.";
  if (m.includes("rate") || m.includes("too many"))
    return "Too many attempts. Please wait a moment and try again.";
  return "Could not sign you in. Please try again.";
}

/** What the address carried: middleware's refusals, notices, and ?reset=1 from /reset-password. */
export type LoginQuery = { error?: string; message?: string; reset?: string };

export default function LoginForm({ query }: { query: LoginQuery }) {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [capsOn, setCapsOn] = useState(false);
  const [loading, setLoading] = useState(false);
  // Start with the message the address carries, so it is in the first HTML too.
  const initial = URL_MESSAGES[query.error ?? query.message ?? ""];
  const [error, setError] = useState<string | null>(initial?.type === "error" ? initial.text : null);
  const [info, setInfo] = useState<string | null>(initial?.type === "info" ? initial.text : null);
  const [resetMode, setResetMode] = useState(query.reset === "1");
  const [resetSent, setResetSent] = useState(false);
  const [googleBusy, setGoogleBusy] = useState(false);

  // Google's button signs the person in, then the admin gate is asked
  // (components/auth/GoogleButton.tsx): only an admin gets past it.
  function handleGoogle(result: GoogleResult) {
    if (result.ok) {
      router.replace(DASHBOARD_HOME);
      return;
    }
    const message = URL_MESSAGES[result.error];
    setError(message.type === "error" ? message.text : null);
    setInfo(message.type === "info" ? message.text : null);
  }

  useEffect(() => {
    const key = query.error ?? query.message;
    if (key && URL_MESSAGES[key]) {
      const { text, type } = URL_MESSAGES[key];
      if (type === "error") setError(text);
      else setInfo(text);
    }
    // "Request a new link" on /reset-password lands here, straight in reset mode.
    if (query.reset === "1") setResetMode(true);
  }, [query.error, query.message, query.reset]);

  async function handleLogin(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);
    setInfo(null);

    const supabase = getSupabaseBrowser();
    const { error: authError } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password,
    });

    if (authError) {
      setError(friendlyAuthError(authError.message));
      setLoading(false);
      return;
    }

    // Straight to the overview in ONE navigation. This was push("/dashboard")
    // then refresh(): two server round trips, then a redirect for a third.
    router.replace(DASHBOARD_HOME);
  }

  async function handleReset(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setInfo(null);
    if (!email.trim()) {
      setError("Enter your email address to reset your password.");
      return;
    }
    setLoading(true);
    // The server decides whether this address gets an email (only an admin's
    // does) and answers every address the same way, so this page never learns
    // which it was — see app/api/admin/password-reset. The link lands on
    // /auth/callback, which opens /reset-password with a recovery session.
    const result = await fetch("/api/admin/password-reset", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email }),
    })
      .then(async (r) => ({ ok: r.ok, message: ((await r.json().catch(() => ({}))) as { message?: string }).message }))
      .catch(() => ({ ok: false, message: "We couldn't reach Help24. Check your connection and try again." }));
    setLoading(false);
    if (!result.ok) {
      setError(result.message ?? "We couldn't send the reset email just now. Try again.");
      return;
    }
    setResetSent(true);
    setInfo(
      `Check your inbox. We've sent a reset link to ${email.trim()} — open it on this device, in this browser. ` +
        "Nothing after a few minutes? Make sure this is the address your admin account uses, or ask a super admin.",
    );
  }

  return (
    <AuthShell
      product="Help24 Operations"
      notice="Authorised Help24 staff only"
      help={SIGN_IN_HELP}
      title={resetMode ? "Reset your password" : "Sign in"}
      subtitle={resetMode ? "We'll email you a link to choose a new one." : undefined}
    >
      <form onSubmit={resetMode ? handleReset : handleLogin} className="space-y-5">
        {info && (
          <div role="status" className="rounded-lg border border-info-200 bg-info-50 px-3.5 py-3 text-[13px] leading-snug text-info-700">
            {info}
          </div>
        )}
        {error && (
          <div role="alert" className="rounded-lg border border-critical-200 bg-critical-50 px-3.5 py-3 text-[13px] leading-snug text-critical-700">
            {error}
          </div>
        )}

        {!resetMode && (
          <GoogleButton
            onBusy={(busy) => {
              setGoogleBusy(busy);
              if (busy) {
                setError(null);
                setInfo(null);
              }
            }}
            onDone={handleGoogle}
          />
        )}
        {googleBusy && (
          <p role="status" className="text-center text-[13px] text-gray-500">
            Signing you in with Google…
          </p>
        )}

        <div>
          <label htmlFor="admin-email" className="block text-sm font-medium text-gray-700 mb-1">
            Email address
          </label>
          <input
            id="admin-email"
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="input"
            placeholder="you@help24.co.ke"
            required
            autoComplete="email"
            inputMode="email"
          />
        </div>

        {!resetMode && (
          <div>
            <div className="flex items-center justify-between mb-1">
              <label htmlFor="admin-password" className="block text-sm font-medium text-gray-700">
                Password
              </label>
              <button
                type="button"
                onClick={() => {
                  setResetMode(true);
                  setError(null);
                  setInfo(null);
                }}
                className="text-[13px] font-medium text-gray-500 hover:text-gray-900 hover:underline"
              >
                Forgot password?
              </button>
            </div>
            <div className="relative">
              <input
                id="admin-password"
                type={showPassword ? "text" : "password"}
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                onKeyDown={(e) => setCapsOn(e.getModifierState("CapsLock"))}
                onKeyUp={(e) => setCapsOn(e.getModifierState("CapsLock"))}
                onBlur={() => setCapsOn(false)}
                className="input pr-11"
                required
                autoComplete="current-password"
              />
              <button
                type="button"
                onClick={() => setShowPassword((s) => !s)}
                aria-label={showPassword ? "Hide password" : "Show password"}
                aria-pressed={showPassword}
                className="absolute inset-y-0 right-0 flex items-center px-3 text-gray-400 hover:text-gray-600"
              >
                <EyeIcon open={showPassword} />
              </button>
            </div>
            {capsOn && <p className="mt-1.5 text-xs font-medium text-caution-700">Caps Lock is on</p>}
          </div>
        )}

        <button type="submit" disabled={loading || resetSent} className="btn-primary w-full">
          {loading
            ? resetMode
              ? "Sending…"
              : "Signing in…"
            : resetMode
              ? "Send reset link"
              : "Sign in"}
        </button>

        {resetMode && (
          <button
            type="button"
            onClick={() => {
              setResetMode(false);
              setResetSent(false);
              setError(null);
              setInfo(null);
            }}
            className="w-full text-center text-[13px] font-medium text-gray-500 hover:text-gray-900"
          >
            ← Back to sign in
          </button>
        )}
      </form>
    </AuthShell>
  );
}
