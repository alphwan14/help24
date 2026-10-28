"use client";

import { useState, useEffect, Suspense } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import { requestPasswordReset } from "@/lib/admin-password";
import { recoveryRedirectUrl } from "@/lib/recovery-session";
import { EyeIcon } from "@/components/PasswordInputs";
import { DASHBOARD_HOME } from "@/lib/routes";
import AuthShell from "@/components/auth/AuthShell";
import { ADMIN_AUDIENCE } from "@/lib/auth-audiences";

/** URL-param messages (set by middleware / redirects). */
const URL_MESSAGES: Record<string, { text: string; type: "info" | "error" }> = {
  unauthorized: {
    text: "Access denied — your account does not have admin privileges.",
    type: "error",
  },
  // Middleware sends this when the password was right but the login is not
  // linked to a Help24 account. Saying "no privileges" here sent one admin
  // through repeated sign-ins and password resets that could never help.
  "not-linked": {
    text: "Your password is correct, but this login isn't connected to a Help24 account yet. A super admin has been alerted — once they link it, sign in here again. There's no need to reset your password.",
    type: "info",
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

function LoginForm() {
  const router = useRouter();
  const params = useSearchParams();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [capsOn, setCapsOn] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const [resetMode, setResetMode] = useState(false);
  const [resetSent, setResetSent] = useState(false);

  useEffect(() => {
    const errorParam = params.get("error");
    const messageParam = params.get("message");
    const key = errorParam ?? messageParam;
    if (key && URL_MESSAGES[key]) {
      const { text, type } = URL_MESSAGES[key];
      if (type === "error") setError(text);
      else setInfo(text);
    }
    // "Request a new link" on /reset-password lands here, straight in reset mode.
    if (params.get("reset") === "1") setResetMode(true);
  }, [params]);

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
    // The link lands on /auth/callback, which opens /reset-password with a
    // recovery session. It used to point back at this page claiming "Password
    // updated", with nothing in between to set one — see lib/recovery-session.ts.
    const result = await requestPasswordReset(
      getSupabaseBrowser().auth,
      email,
      recoveryRedirectUrl(window.location.origin),
    );
    setLoading(false);
    if (!result.ok) {
      setError(result.message);
      return;
    }
    setResetSent(true);
    setInfo(
      "If that email has an admin account, a reset link is on its way. Open it in this browser — it won't work anywhere else.",
    );
  }

  return (
    <AuthShell
      audience={ADMIN_AUDIENCE}
      title={resetMode ? "Reset your password" : "Welcome back"}
      subtitle={
        resetMode
          ? "Enter the email you sign in with and we'll send you a link to choose a new password."
          : "Sign in to the Help24 operations console."
      }
      below={<p>Admin access is by invitation only — there is no public sign-up.</p>}
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

export default function LoginPage() {
  return (
    <Suspense>
      <LoginForm />
    </Suspense>
  );
}
