"use client";

import { useState, useEffect, Suspense } from "react";
import Image from "next/image";
import { useRouter, useSearchParams } from "next/navigation";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import { requestPasswordReset } from "@/lib/admin-password";
import { recoveryRedirectUrl } from "@/lib/recovery-session";
import { EyeIcon } from "@/components/PasswordInputs";

/** URL-param messages (set by middleware / redirects). */
const URL_MESSAGES: Record<string, { text: string; type: "info" | "error" }> = {
  unauthorized: {
    text: "Access denied — your account does not have admin privileges.",
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

    router.push("/dashboard");
    router.refresh();
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
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-rail-950 to-rail-900 p-4">
      <div className="w-full max-w-sm">
        {/* Header */}
        <div className="text-center mb-8">
          {/* The mark carries its own squircle, so it sits on the page with no
              plate — same as the sidebar. */}
          <Image
            src="/help24.png"
            alt="Help24 logo"
            width={56}
            height={56}
            className="w-14 h-14 mx-auto mb-4"
            priority
          />
          <h1 className="text-2xl font-bold text-rail-50">Help24 Admin</h1>
          <p className="text-rail-200 text-sm mt-1">
            {resetMode ? "Reset your password" : "Sign in to the operations console"}
          </p>
        </div>

        <div className="card p-6">
          <form onSubmit={resetMode ? handleReset : handleLogin} className="space-y-4">
            {info && (
              <div className="p-3 rounded-lg bg-blue-50 border border-blue-200 text-blue-700 text-sm flex gap-2">
                <span>ℹ</span>
                <span>{info}</span>
              </div>
            )}
            {error && (
              <div className="p-3 rounded-lg bg-red-50 border border-red-200 text-red-700 text-sm flex gap-2">
                <span>✕</span>
                <span>{error}</span>
              </div>
            )}

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Email address
              </label>
              <input
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="input"
                placeholder="you@help24.app"
                required
                autoComplete="email"
              />
            </div>

            {!resetMode && (
              <div>
                <div className="flex items-center justify-between mb-1">
                  <label className="block text-sm font-medium text-gray-700">
                    Password
                  </label>
                  <button
                    type="button"
                    onClick={() => {
                      setResetMode(true);
                      setError(null);
                      setInfo(null);
                    }}
                    className="text-xs text-brand-600 hover:text-brand-800 hover:underline"
                  >
                    Forgot password?
                  </button>
                </div>
                <div className="relative">
                  <input
                    type={showPassword ? "text" : "password"}
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    className="input pr-10"
                    placeholder="••••••••"
                    required
                    autoComplete="current-password"
                  />
                  <button
                    type="button"
                    onClick={() => setShowPassword((s) => !s)}
                    aria-label={showPassword ? "Hide password" : "Show password"}
                    className="absolute inset-y-0 right-0 flex items-center px-3 text-gray-400 hover:text-gray-600"
                  >
                    <EyeIcon open={showPassword} />
                  </button>
                </div>
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
                className="w-full text-center text-xs text-gray-500 hover:text-gray-700"
              >
                ← Back to sign in
              </button>
            )}
          </form>
        </div>

        <p className="text-center text-rail-200/80 text-xs mt-5 leading-relaxed">
          Admins are invited by system administrators.
          <br />
          There is no public sign-up.
        </p>
      </div>
    </div>
  );
}

export default function LoginPage() {
  return (
    <Suspense>
      <LoginForm />
    </Suspense>
  );
}
