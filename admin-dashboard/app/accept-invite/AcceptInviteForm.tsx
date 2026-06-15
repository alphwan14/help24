"use client";

import { useActionState, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import { acceptInvite, type AcceptState } from "@/lib/admin-actions";
import type { AdminRole } from "@/lib/api";

const initial: AcceptState = { ok: false };

const ROLE_LABELS: Record<AdminRole, string> = {
  support_agent: "Support Agent",
  senior_admin: "Senior Admin",
  super_admin: "Super Admin",
};

type Finishing = "idle" | "signing-in" | "redirecting" | "manual";

export default function AcceptInviteForm({
  token,
  email,
  role,
  expiresAt,
}: {
  token: string;
  email: string;
  role: AdminRole;
  expiresAt: string;
}) {
  const router = useRouter();
  const [state, formAction, pending] = useActionState(acceptInvite, initial);
  const [showPassword, setShowPassword] = useState(false);

  // Keep the password in memory ONLY to establish the dashboard session right
  // after provisioning — it is never stored, logged, or sent anywhere but the
  // standard Supabase sign-in. Cleared once we redirect.
  const [password, setPassword] = useState("");
  const passwordRef = useRef("");
  passwordRef.current = password;

  const [finishing, setFinishing] = useState<Finishing>("idle");
  const finishStarted = useRef(false);

  const succeeded = state.ok && !!state.result;

  /**
   * On successful provisioning, complete onboarding seamlessly:
   *   1. acceptInvite() (server) already set the secure session cookie.
   *   2. Establish the Supabase dashboard session with the password just set.
   *   3. Redirect straight into the dashboard — fully connected, no token UI.
   *
   * If the silent sign-in fails for any reason, we fall back to the sign-in
   * screen (the account is already provisioned, so they just sign in once).
   */
  useEffect(() => {
    if (!succeeded || finishStarted.current) return;
    finishStarted.current = true;

    void (async () => {
      setFinishing("signing-in");
      try {
        const { error } = await getSupabaseBrowser().auth.signInWithPassword({
          email: email.trim(),
          password: passwordRef.current,
        });
        if (error) {
          // Provisioning succeeded; only the auto sign-in didn't. Send them to
          // the sign-in screen rather than stranding them.
          setFinishing("manual");
          router.push("/login?message=invite-accepted");
          return;
        }
        setPassword("");
        setFinishing("redirecting");
        router.push("/dashboard");
        router.refresh();
      } catch {
        setFinishing("manual");
        router.push("/login?message=invite-accepted");
      }
    })();
  }, [succeeded, email, router]);

  // ── Success: seamless hand-off (no tokens, no copying) ───────────────────────
  if (succeeded) {
    return (
      <div className="card p-8 text-center space-y-4">
        <div className="mx-auto w-11 h-11 rounded-full border-2 border-brand-200 border-t-brand-600 animate-spin" />
        <div>
          <h2 className="text-lg font-bold text-gray-900">
            Setting up your workspace
          </h2>
          <p className="text-sm text-gray-500 mt-1">
            {finishing === "manual"
              ? "Almost there — taking you to sign in…"
              : "Signing you in and getting everything ready…"}
          </p>
        </div>
        <p className="text-xs text-gray-400">This only takes a moment.</p>
      </div>
    );
  }

  // ── Form ──────────────────────────────────────────────────────────────────
  return (
    <div className="card p-6 space-y-4">
      <div>
        <div className="flex items-center gap-2 mb-1">
          <span className="badge bg-green-100 text-green-700">✓ Valid invitation</span>
        </div>
        <p className="text-sm text-gray-500">You&apos;ve been invited to join as</p>
        <p className="font-semibold text-gray-900">{email}</p>
        <span className="badge bg-indigo-100 text-indigo-700 mt-1 inline-block">
          {ROLE_LABELS[role] ?? role}
        </span>
      </div>

      <form action={formAction} className="space-y-4">
        <input type="hidden" name="token" value={token} />

        {state.error && (
          <div className="p-3 rounded-lg bg-red-50 border border-red-200 text-red-700 text-sm flex gap-2">
            <span>✕</span>
            <span>{state.error}</span>
          </div>
        )}

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Full name</label>
          <input name="name" type="text" className="input" placeholder="Jane Doe" required minLength={2} />
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            Create password
          </label>
          <div className="relative">
            <input
              name="password"
              type={showPassword ? "text" : "password"}
              className="input pr-16"
              placeholder="Min 8 characters"
              required
              minLength={8}
              autoComplete="new-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
            <button
              type="button"
              onClick={() => setShowPassword((s) => !s)}
              className="absolute inset-y-0 right-0 flex items-center px-3 text-xs text-gray-400 hover:text-gray-600"
            >
              {showPassword ? "Hide" : "Show"}
            </button>
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            Confirm password
          </label>
          <input
            name="confirm"
            type={showPassword ? "text" : "password"}
            className="input"
            placeholder="Re-enter password"
            required
            minLength={8}
            autoComplete="new-password"
          />
        </div>

        <button type="submit" disabled={pending} className="btn-primary w-full">
          {pending ? "Setting up your account…" : "Accept invitation"}
        </button>
        {pending && (
          <p className="text-center text-xs text-gray-400">
            Setting things up — this is safe to wait on, don&apos;t refresh.
          </p>
        )}
      </form>

      <p className="text-xs text-gray-400 text-center">
        Invitation valid until {new Date(expiresAt).toLocaleDateString("en-KE", {
          day: "2-digit",
          month: "short",
          year: "numeric",
        })}
      </p>
    </div>
  );
}
