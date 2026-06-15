"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import {
  restoreArbitration,
  type ArbitrationIdentity,
} from "@/lib/arbitration-client";
import { clearArbitrationToken } from "@/lib/admin-actions";
import Sidebar from "@/components/Sidebar";
import ConnectAccess from "@/app/dashboard/disputes/ConnectAccess";

type Status = "checking" | "ready" | "recovery";

/**
 * Authenticated app shell. This is the SINGLE place arbitration access is
 * established: on load it detects the Supabase session and silently restores the
 * arbitration token before any admin UI is shown. The dashboard, sidebar and all
 * admin routes stay behind a "Setting up your admin workspace…" splash until the
 * arbitration state is confirmed — so a normal login never surfaces a reconnect
 * prompt or token field.
 *
 * Recovery (ConnectAccess) is reached ONLY when a valid Supabase session cannot
 * be turned into arbitration access (no admin record, inactive/revoked, backend
 * failure) — the genuine error states.
 */
export default function AdminShell({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const [status, setStatus] = useState<Status>("checking");
  const [supabaseEmail, setSupabaseEmail] = useState<string | null>(null);
  const [arbitration, setArbitration] = useState<ArbitrationIdentity>({
    connected: false,
  });
  const resolved = useRef(false);

  useEffect(() => {
    if (resolved.current) return;
    resolved.current = true;

    void (async () => {
      // 1. Supabase session email (client-cached — no network).
      let sessionEmail: string | null = null;
      try {
        const { data } = await getSupabaseBrowser().auth.getSession();
        sessionEmail = data.session?.user.email ?? null;
      } catch {
        /* no session — middleware will redirect */
      }
      setSupabaseEmail(sessionEmail);

      // 2. Current arbitration identity (cheap GET — no rotation if connected).
      let ident: ArbitrationIdentity = { connected: false };
      try {
        const r = await fetch("/api/admin/identity");
        ident = (await r.json()) as ArbitrationIdentity;
      } catch {
        /* fall through to restore */
      }

      // 3. Not connected → silently restore from the authenticated session.
      let didRestore = false;
      if (!ident.connected) {
        ident = await restoreArbitration();
        if (ident.connected) didRestore = true;
      }

      // 4. Identity mismatch → clear the stale token and reconnect AS THE
      //    CURRENT session user. No foreign arbitration state can survive.
      if (
        ident.connected &&
        sessionEmail &&
        ident.email &&
        sessionEmail.toLowerCase() !== ident.email.toLowerCase()
      ) {
        await clearArbitrationToken();
        ident = await restoreArbitration(true);
        didRestore = true;
      }

      setArbitration(ident);

      // 5. If the cookie changed, re-render server pages so they see it.
      if (didRestore && ident.connected) router.refresh();

      // 6. Commit readiness. Recovery only when a real session can't connect.
      if (ident.connected) setStatus("ready");
      else if (sessionEmail) setStatus("recovery");
      else setStatus("ready"); // no session → middleware redirects to /login
    })();
  }, [router]);

  return (
    <div className="bg-slate-50 lg:flex lg:h-screen lg:overflow-hidden">
      <Sidebar supabaseEmail={supabaseEmail} arbitration={arbitration} />
      <main className="flex-1 min-w-0 overflow-y-auto pt-14 lg:pt-0">
        <div className="max-w-[1320px] mx-auto px-4 sm:px-6 lg:px-8 py-5 sm:py-6 lg:py-8">
          {children}
        </div>
      </main>

      {status === "checking" && <Splash />}
      {status === "recovery" && <RecoveryOverlay />}
    </div>
  );
}

/** Opaque full-screen splash — shown until arbitration access is confirmed. */
function Splash() {
  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-slate-50">
      <div className="text-center space-y-4 px-6">
        <div className="mx-auto w-11 h-11 rounded-full border-2 border-brand-200 border-t-brand-600 animate-spin" />
        <div>
          <p className="text-sm font-semibold text-gray-800">
            Setting up your admin workspace…
          </p>
          <p className="text-xs text-gray-400 mt-1">This only takes a moment.</p>
        </div>
      </div>
    </div>
  );
}

/** Genuine recovery only — a valid session that can't be granted arbitration. */
function RecoveryOverlay() {
  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-slate-50 p-4">
      <ConnectAccess />
    </div>
  );
}
