"use client";

import { useEffect } from "react";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import { signOutOfConsole } from "@/lib/sign-out-client";
import { ACTIVE_AT_KEY, pastIdleLimit, signedInAt } from "@/lib/session-limits";

const WRITE_EVERY = 10_000;
const CHECK_EVERY = 20_000;

/**
 * The 30-minute idle limit (lib/session-limits.ts). Any touch in any console
 * tab (a key, a click, a scroll, a pointer move) counts as activity, shared
 * through localStorage, so reading in one tab keeps the others signed in.
 * When nobody has touched the console for 30 minutes, every tab signs out.
 * A laptop that slept past the limit signs out the moment it wakes.
 */
export default function IdleSignOut({ enabled }: { enabled: boolean }) {
  useEffect(() => {
    if (!enabled) return;
    let lastWrite = 0;
    let signedIn: number | null = null;
    let leaving = false;

    const read = (): number | null => {
      try {
        const v = Number(localStorage.getItem(ACTIVE_AT_KEY));
        return Number.isFinite(v) && v > 0 ? v : null;
      } catch {
        return null;
      }
    };
    const touch = () => {
      const now = Date.now();
      if (now - lastWrite < WRITE_EVERY) return;
      lastWrite = now;
      try {
        localStorage.setItem(ACTIVE_AT_KEY, String(now));
      } catch {
        /* private mode: this tab still counts its own activity below */
      }
    };
    // This tab's own last touch. Opening the page does not count until the
    // check below has run: reopening a tab after two idle hours is not activity.
    let local = 0;
    const onActivity = () => {
      local = Date.now();
      touch();
    };
    const check = () => {
      if (leaving) return;
      const last = Math.max(read() ?? 0, local);
      if (pastIdleLimit(last, signedIn)) {
        leaving = true;
        void signOutOfConsole("/login?error=signed-out-idle");
      }
    };

    void getSupabaseBrowser()
      .auth.getSession()
      .then((res: { data: { session: { access_token: string } | null } }) => {
        signedIn = signedInAt(res.data.session?.access_token);
        check();
        if (!leaving) {
          local = Date.now();
          touch();
        }
      });

    const events = ["pointerdown", "pointermove", "keydown", "wheel", "touchstart", "scroll"] as const;
    for (const e of events) window.addEventListener(e, onActivity, { passive: true, capture: true });
    const onVisible = () => document.visibilityState === "visible" && check();
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("focus", check);
    const timer = setInterval(check, CHECK_EVERY);

    return () => {
      for (const e of events) window.removeEventListener(e, onActivity, { capture: true });
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("focus", check);
      clearInterval(timer);
    };
  }, [enabled]);

  return null;
}
