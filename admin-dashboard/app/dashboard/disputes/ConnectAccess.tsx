"use client";

import { useActionState } from "react";
import { connectArbitration, type ConnectState } from "@/lib/disputes-actions";

const initial: ConnectState = { ok: false };

/**
 * Token gate. The admin pastes their backend bearer token once; the server
 * action validates it against GET /admin/me and stores it in an httpOnly cookie.
 * The token never touches client JS beyond this submit — after this the page
 * re-renders server-side with live data.
 */
export default function ConnectAccess() {
  const [state, formAction, pending] = useActionState(connectArbitration, initial);

  return (
    <div className="max-w-md mx-auto">
      <div className="card p-6 space-y-4">
        <div>
          <h2 className="text-lg font-bold text-gray-900">Connect arbitration access</h2>
          <p className="text-sm text-gray-500 mt-1">
            Disputes are served by the secured backend. Paste your admin access
            token to continue. It is stored in a secure httpOnly cookie and never
            exposed to the browser.
          </p>
        </div>

        <form action={formAction} className="space-y-3">
          <div>
            <label className="text-xs font-semibold text-gray-500 block mb-1">
              Admin access token
            </label>
            <input
              type="password"
              name="token"
              className="input w-full font-mono"
              placeholder="paste your bearer token"
              autoComplete="off"
              required
            />
          </div>

          {state.error && (
            <div className="p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-600">
              {state.error}
            </div>
          )}

          <button type="submit" disabled={pending} className="btn-primary w-full">
            {pending ? "Verifying…" : "Connect"}
          </button>
        </form>

        <p className="text-xs text-gray-400">
          Tokens are issued by a super_admin via <span className="font-mono">POST /admin/admins</span>.
          They are shown once and cannot be recovered.
        </p>
      </div>
    </div>
  );
}
