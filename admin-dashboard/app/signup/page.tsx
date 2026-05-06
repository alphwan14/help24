"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { getSupabaseBrowser } from "@/lib/supabase-browser";

export default function SignupPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSignup(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);

    const supabase = getSupabaseBrowser();

    // Create Supabase Auth user
    const { data, error: signUpError } = await supabase.auth.signUp({ email, password });

    if (signUpError) {
      setError(signUpError.message);
      setLoading(false);
      return;
    }

    const authUser = data.user;

    // Upsert into public.users keyed by email.
    // ON CONFLICT (email) DO UPDATE keeps the existing row (preserves promoted roles).
    if (authUser) {
      const { error: upsertError } = await supabase.from("users").upsert(
        {
          id: authUser.id,
          email: authUser.email ?? email,
          role: "user",
        },
        {
          onConflict: "email",
          ignoreDuplicates: true, // never downgrade role if row already exists
        }
      );

      if (upsertError) {
        // Non-fatal — admin can still promote via SQL using email lookup
        console.warn("[Signup] users upsert error:", upsertError.message);
      }
    }

    // Sign out immediately — admin must grant role before they can access anything
    await supabase.auth.signOut();

    router.push("/login?message=account-created");
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-brand-900 to-brand-700 p-4">
      <div className="w-full max-w-sm">
        {/* Header */}
        <div className="text-center mb-8">
          <div className="inline-flex items-center justify-center w-14 h-14 rounded-2xl bg-white/10 mb-4">
            <span className="text-2xl font-bold text-white">H</span>
          </div>
          <h1 className="text-2xl font-bold text-white">Create Admin Account</h1>
          <p className="text-brand-200 text-sm mt-1">Help24 Admin Dashboard</p>
        </div>

        <div className="card p-6">
          <form onSubmit={handleSignup} className="space-y-4">
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
                placeholder="you@example.com"
                required
                autoComplete="email"
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Password
              </label>
              <input
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="input"
                placeholder="Min 6 characters"
                required
                minLength={6}
                autoComplete="new-password"
              />
            </div>

            <button type="submit" disabled={loading} className="btn-primary w-full">
              {loading ? "Creating account…" : "Create account"}
            </button>
          </form>

          {/* First-admin instructions */}
          <div className="mt-5 p-3 rounded-lg bg-amber-50 border border-amber-200">
            <p className="text-xs font-semibold text-amber-800 mb-1">First-time setup</p>
            <p className="text-xs text-amber-700">
              After creating your account, run this SQL in the Supabase SQL editor to grant admin access:
            </p>
            <code className="block mt-2 text-xs bg-amber-100 text-amber-900 rounded p-2 font-mono leading-relaxed break-all">
              {`UPDATE public.users\nSET role = 'admin'\nWHERE email = 'your@email.com';`}
            </code>
          </div>
        </div>

        <p className="text-center text-brand-300 text-xs mt-4">
          Already have an account?{" "}
          <Link href="/login" className="text-white underline hover:text-brand-100">
            Sign in
          </Link>
        </p>
      </div>
    </div>
  );
}
