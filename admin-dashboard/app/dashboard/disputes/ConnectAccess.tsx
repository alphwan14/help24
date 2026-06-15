"use client";

import { useActionState, useState } from "react";
import Link from "next/link";
import { connectArbitration, type ConnectState } from "@/lib/disputes-actions";

const initial: ConnectState = { ok: false };

/**
 * RECOVERY screen — shown only when a secure session could not be found
 * (expired, revoked, signed out, or a fresh device). It is NOT part of normal
 * onboarding: accepting an invite signs the admin in and connects automatically.
 *
 * For everyday admins the fix is simply "sign in again". The manual access-token
 * field is a developer/support fallback, tucked behind an Advanced disclosure.
 */
export default function ConnectAccess() {
  const [state, formAction, pending] = useActionState(connectArbitration, initial);
  const [advancedOpen, setAdvancedOpen] = useState(false);

  return (
    <div className="max-w-md mx-auto">
      <div className="card p-6 space-y-5">
        <div className="text-center space-y-2">
          <div className="mx-auto w-11 h-11 rounded-full bg-amber-50 border border-amber-200 flex items-center justify-center text-amber-600">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.75} className="w-5 h-5">
              <path strokeLinecap="round" strokeLinejoin="round" d="M16.5 10.5V6.75a4.5 4.5 0 10-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 002.25-2.25v-6.75a2.25 2.25 0 00-2.25-2.25H6.75a2.25 2.25 0 00-2.25 2.25v6.75a2.25 2.25 0 002.25 2.25z" />
            </svg>
          </div>
          <h2 className="text-lg font-bold text-gray-900">Your session needs refreshing</h2>
          <p className="text-sm text-gray-500">
            We couldn&apos;t verify your secure session. This usually happens after
            a while away or on a new device. Sign in again to continue.
          </p>
        </div>

        <Link href="/login" className="btn-primary w-full text-center block">
          Sign in again
        </Link>

        {/* Developer / support fallback — hidden by default. */}
        <div className="pt-1 border-t border-gray-100">
          <button
            type="button"
            onClick={() => setAdvancedOpen((o) => !o)}
            className="text-xs text-gray-400 hover:text-gray-600 transition-colors"
          >
            {advancedOpen ? "▾" : "▸"} Advanced
          </button>

          {advancedOpen && (
            <form action={formAction} className="space-y-3 mt-3">
              <p className="text-xs text-gray-400">
                Support staff can reconnect with a one-time access key issued by a
                workspace owner. It is stored securely and never shown again.
              </p>
              <input
                type="password"
                name="token"
                className="input w-full font-mono"
                placeholder="Access key"
                autoComplete="off"
                required
              />
              {state.error && (
                <div className="p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-600">
                  {state.error}
                </div>
              )}
              <button
                type="submit"
                disabled={pending}
                className="btn-ghost w-full border border-gray-200"
              >
                {pending ? "Verifying…" : "Reconnect with access key"}
              </button>
            </form>
          )}
        </div>
      </div>
    </div>
  );
}
