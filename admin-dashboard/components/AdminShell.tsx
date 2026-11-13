"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import {
  restoreArbitration,
  type ArbitrationIdentity,
} from "@/lib/arbitration-client";
import { clearArbitrationToken } from "@/lib/admin-actions";
import Sidebar from "@/components/Sidebar";
import AlertsProvider from "@/components/alerts/AlertsProvider";
import ConsolePresence from "@/components/ConsolePresence";
import ConnectAccess from "@/app/dashboard/disputes/ConnectAccess";
import CommandPalette from "@/components/CommandPalette";
import { ShellContext, type Shell } from "@/components/ShellContext";

type Status = "checking" | "restoring" | "ready" | "recovery";

/** The last confirmed identity, so the nav knows the admin's role on the first
 *  paint. Per browser; checked against the live answer moments later. */
const IDENTITY_KEY = "h24_admin_identity";

function cachedIdentity(): ArbitrationIdentity {
  try {
    const raw = localStorage.getItem(IDENTITY_KEY);
    const v = raw ? (JSON.parse(raw) as ArbitrationIdentity) : null;
    return v && v.connected ? v : { connected: false };
  } catch {
    return { connected: false };
  }
}

function rememberIdentity(ident: ArbitrationIdentity) {
  try {
    if (ident.connected) localStorage.setItem(IDENTITY_KEY, JSON.stringify(ident));
    else localStorage.removeItem(IDENTITY_KEY);
  } catch {
    /* private mode: the nav waits for the live answer instead */
  }
}

/**
 * Authenticated app shell. This is the SINGLE place arbitration access is
 * established: on load it detects the Supabase session and silently restores the
 * arbitration token if it is missing.
 *
 * The page shows AT ONCE. Middleware has already checked the session and the
 * server already rendered the page with the admin cookie, so in the normal case
 * (cookie present) there is nothing to wait for: the check runs behind the page
 * and the nav uses the role this browser last saw. The full-screen "Opening the
 * console" splash appears only in the rare case that access must actually be
 * restored (first visit after sign-in, or a token for another account), and the
 * recovery screen only when it cannot be.
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
  // Read after mount (localStorage is not on the server), before paint.
  useEffect(() => {
    const cached = cachedIdentity();
    if (cached.connected) setArbitration((a) => (a.connected ? a : cached));
  }, []);
  const resolved = useRef(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const openSearch = useCallback(() => setSearchOpen(true), []);

  // Ctrl+K / Cmd+K opens search from anywhere, and toggles it closed again.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setSearchOpen((o) => !o);
      }
    }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  const role = arbitration.connected ? (arbitration.role ?? null) : null;
  const shell = useMemo<Shell>(() => ({ role, openSearch }), [role, openSearch]);

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

      // 3. Not connected → restore from the authenticated session. Only now
      //    does the page step aside: it was rendered without access.
      let didRestore = false;
      if (!ident.connected) {
        if (sessionEmail) setStatus("restoring");
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
        setStatus("restoring");
        await clearArbitrationToken();
        ident = await restoreArbitration(true);
        didRestore = true;
      }

      setArbitration(ident);
      rememberIdentity(ident);

      // 5. If the cookie changed, re-render server pages so they see it.
      if (didRestore && ident.connected) router.refresh();

      // 6. Commit readiness. Recovery only when a real session can't connect.
      if (ident.connected) setStatus("ready");
      else if (sessionEmail) setStatus("recovery");
      else setStatus("ready"); // no session → middleware redirects to /login
    })();
  }, [router]);

  return (
    <ShellContext.Provider value={shell}>
      {/* Alerts start only once admin access is confirmed; they are read with
          the same admin token as every other admin surface. The provider now
          wraps the whole shell, so the nav counts, the phone's bottom bar and
          Overview's attention list all read the one poll. */}
      <AlertsProvider enabled={status === "ready" && arbitration.connected}>
        <div className="bg-page lg:flex lg:h-screen lg:overflow-hidden">
          <Sidebar supabaseEmail={supabaseEmail} arbitration={arbitration} />
          {/* `relative` is load-bearing. Without a positioned <main>, an
              absolutely positioned descendant with no positioned ancestor
              (every `sr-only` span is one; Settings' password checklist has
              several) is placed against the PAGE, escapes this scroll box,
              and makes the document taller than the screen: the window then
              scrolls and drags the rail up with it (33 px on Settings at
              1366x768). */}
          <main className="relative flex-1 min-w-0 overflow-y-auto pt-14 lg:pt-0">
            <div className="max-w-[1280px] mx-auto px-4 sm:px-6 lg:px-10 py-5 sm:py-6 lg:py-8">
              {children}
            </div>
          </main>

          {/* Who is in the console now; Admin Roles reads it (migration 132). */}
          <ConsolePresence enabled={status === "ready"} />
          <CommandPalette open={searchOpen} onClose={() => setSearchOpen(false)} role={role} />
          {status === "restoring" && <Splash />}
          {status === "recovery" && <RecoveryOverlay />}
        </div>
      </AlertsProvider>
    </ShellContext.Provider>
  );
}

/** Opaque full-screen splash, only while access is being restored. */
function Splash() {
  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-page">
      <div className="text-center space-y-4 px-6">
        <div className="mx-auto w-11 h-11 rounded-full border-2 border-brand-200 border-t-brand-600 animate-spin" />
        <div>
          <p className="text-sm font-semibold text-gray-800">
            Opening the console
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
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-page p-4">
      <ConnectAccess />
    </div>
  );
}
