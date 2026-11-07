"use client";

import { useState, useEffect, Suspense } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import { EyeIcon } from "@/components/PasswordInputs";
import { DASHBOARD_HOME } from "@/lib/routes";
import AuthShell from "@/components/auth/AuthShell";
import { SIGN_IN_HELP } from "@/lib/auth-audiences";
import { GOOGLE_FLOW_COOKIE, GOOGLE_FLOW_MAX_AGE, googleRedirectUrl } from "@/lib/google-sign-in";

/**
 * Whether Google sign-in is switched on in Supabase, from its public settings.
 * Until it is, the button stays hidden: pressing it would land on the
 * provider's raw "provider is not enabled" page.
 */
async function googleEnabled(): Promise<boolean> {
  try {
    const res = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/auth/v1/settings`, {
      headers: { apikey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY! },
    });
    const body = (await res.json()) as { external?: { google?: boolean } };
    return res.ok && body.external?.google === true;
  } catch {
    return false;
  }
}

/** Google's "G", in its four brand colours (Google sign-in branding guidelines). */
function GoogleMark() {
  return (
    <svg viewBox="0 0 48 48" width="18" height="18" aria-hidden="true">
      <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z" />
      <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z" />
      <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z" />
      <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z" />
    </svg>
  );
}

/** URL-param messages (set by middleware / redirects). */
const URL_MESSAGES: Record<string, { text: string; type: "info" | "error" }> = {
  unauthorized: {
    text: "Access denied — your account does not have admin privileges.",
    type: "error",
  },
  // Middleware (or the Google callback) sends this when sign-in worked but the
  // login is not linked to a Help24 account. Saying "no privileges" here sent
  // one admin through repeated sign-ins and password resets that could never help.
  "not-linked": {
    text: "You signed in, but this login isn't connected to a Help24 account yet. A super admin has been alerted — once they link it, sign in here again. There's no need to reset your password.",
    type: "info",
  },
  // app/auth/callback: the Google account is not a Help24 admin login. The
  // person has just proved they own it, so saying so reveals nothing about
  // anyone else.
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
  const [google, setGoogle] = useState<"hidden" | "ready" | "leaving">("hidden");

  useEffect(() => {
    let live = true;
    void googleEnabled().then((on) => live && on && setGoogle("ready"));
    return () => {
      live = false;
    };
  }, []);

  // Google decides who the person is; app/auth/callback then asks the admin
  // gate, and only an admin's Google account gets past it.
  async function handleGoogle() {
    setError(null);
    setInfo(null);
    setGoogle("leaving");
    document.cookie =
      `${GOOGLE_FLOW_COOKIE}=1; Max-Age=${GOOGLE_FLOW_MAX_AGE}; Path=/; SameSite=Lax` +
      (window.location.protocol === "https:" ? "; Secure" : "");
    const { error: oauthError } = await getSupabaseBrowser().auth.signInWithOAuth({
      provider: "google",
      options: { redirectTo: googleRedirectUrl(window.location.origin), queryParams: { prompt: "select_account" } },
    });
    if (oauthError) {
      setGoogle("ready");
      setError("Google sign-in isn't available right now. Sign in with your email and password.");
    }
  }

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

        {!resetMode && google !== "hidden" && (
          <>
            <button
              type="button"
              onClick={handleGoogle}
              disabled={google === "leaving" || loading}
              className="inline-flex w-full items-center justify-center gap-3 rounded-lg border border-gray-300 bg-surface px-4 py-2.5 text-sm font-medium text-gray-800 transition-colors hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-2 disabled:opacity-60"
              style={{ minHeight: 44 }}
            >
              <GoogleMark />
              {google === "leaving" ? "Opening Google…" : "Continue with Google"}
            </button>
            <div className="flex items-center gap-3 text-xs text-gray-400" aria-hidden="true">
              <span className="h-px flex-1 bg-gray-200" />
              or
              <span className="h-px flex-1 bg-gray-200" />
            </div>
          </>
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
