"use client";

import { useEffect } from "react";

const EVERY_MS = 60_000;

/**
 * The console's heartbeat: once a minute while this tab is visible, and at
 * once when it becomes visible again (/api/admin/presence, migration 132).
 * A hidden or closed tab sends nothing, so "In the console now" on Admin
 * Roles means someone is actually looking at it. Renders nothing.
 */
export default function ConsolePresence({ enabled }: { enabled: boolean }) {
  useEffect(() => {
    if (!enabled) return;
    const beat = () => {
      if (document.visibilityState !== "visible") return;
      void fetch("/api/admin/presence", { method: "POST", keepalive: true }).catch(() => {});
    };
    beat();
    const timer = setInterval(beat, EVERY_MS);
    document.addEventListener("visibilitychange", beat);
    return () => {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", beat);
    };
  }, [enabled]);
  return null;
}
