"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import type { AdminAlert, AlertsResponse } from "@/lib/alerts";

/**
 * One owner for the alert list, shared by every bell on screen (the desktop
 * rail and the mobile top bar are both mounted at once).
 *
 * POLLING: every 2 minutes while the tab is visible, again when it becomes
 * visible after 30s or more away, and never while hidden — an admin with the
 * dashboard open in a background tab costs nothing.
 *
 * REVIEWS are the server's (admin_alert_reviews, migration 117): an alert an
 * admin reviewed is quiet for EVERY admin, for exactly the records it named,
 * and raised again the moment a record joins or leaves it. This replaced a
 * per-browser acknowledgement that no other admin could see — and that this
 * provider silently forgot whenever one check was briefly unavailable, which is
 * why the bell's count kept coming back.
 */

const POLL_MS = 120_000;
const REFOCUS_STALE_MS = 30_000;

type State = {
  data: AlertsResponse | null;
  error: string | null;
  loading: boolean;
  fetchedAt: number | null;
};

type Ctx = State & {
  enabled: boolean;
  refresh: () => void;
  /** Swap one alert for the version the server returned after a review. */
  replaceAlert: (alert: AdminAlert) => void;
  /** Unreviewed HIGH alerts — the only number the bell ever shows. */
  urgentCount: number;
  /** Anything unreviewed at MEDIUM — shown as a dot, never a number. */
  hasUnreadMedium: boolean;
};

const AlertsContext = createContext<Ctx | null>(null);

export function useAlerts(): Ctx | null {
  return useContext(AlertsContext);
}

export default function AlertsProvider({ enabled, children }: { enabled: boolean; children: React.ReactNode }) {
  const [state, setState] = useState<State>({ data: null, error: null, loading: false, fetchedAt: null });
  const inFlight = useRef<AbortController | null>(null);
  const fetchedAtRef = useRef<number | null>(null);

  const load = useCallback(async () => {
    if (!enabled) return;
    inFlight.current?.abort();
    const controller = new AbortController();
    inFlight.current = controller;
    setState((s) => ({ ...s, loading: true }));
    try {
      const res = await fetch("/api/admin/alerts", { cache: "no-store", signal: controller.signal });
      const body = await res.json().catch(() => null);
      if (!res.ok || !body || !Array.isArray(body.alerts)) {
        const message = (body && typeof body.message === "string" && body.message) || "Could not load alerts.";
        setState((s) => ({ ...s, loading: false, error: message }));
        return;
      }
      fetchedAtRef.current = Date.now();
      setState({ data: body as AlertsResponse, error: null, loading: false, fetchedAt: fetchedAtRef.current });
    } catch (err) {
      if ((err as { name?: string })?.name === "AbortError") return;
      setState((s) => ({ ...s, loading: false, error: "Could not reach the alert service." }));
    }
  }, [enabled]);

  useEffect(() => {
    if (!enabled) return;
    void load();
    const timer = window.setInterval(() => {
      if (document.visibilityState === "visible") void load();
    }, POLL_MS);
    const onVisible = () => {
      if (document.visibilityState !== "visible") return;
      const last = fetchedAtRef.current;
      if (!last || Date.now() - last > REFOCUS_STALE_MS) void load();
    };
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("focus", onVisible);
    return () => {
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("focus", onVisible);
      inFlight.current?.abort();
    };
  }, [enabled, load]);

  const replaceAlert = useCallback((alert: AdminAlert) => {
    setState((s) =>
      s.data ? { ...s, data: { ...s.data, alerts: s.data.alerts.map((a) => (a.id === alert.id ? alert : a)) } } : s,
    );
  }, []);

  const value = useMemo<Ctx>(() => {
    const open = (state.data?.alerts ?? []).filter((a) => !a.review);
    return {
      ...state,
      enabled,
      refresh: () => void load(),
      replaceAlert,
      urgentCount: open.filter((a) => a.priority === "high").length,
      hasUnreadMedium: open.some((a) => a.priority === "medium"),
    };
  }, [state, enabled, load, replaceAlert]);

  return <AlertsContext.Provider value={value}>{children}</AlertsContext.Provider>;
}
