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
 * ACKNOWLEDGING: per admin, per alert, for the exact set of records it named
 * (its fingerprint). If a new record joins the alert, the fingerprint changes
 * and it is raised again. Stored in this browser only — a convenience for the
 * person looking, never a way to hide a problem from the other admins.
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
  isAcknowledged: (a: AdminAlert) => boolean;
  acknowledge: (a: AdminAlert) => void;
  unacknowledge: (a: AdminAlert) => void;
  /** Unacknowledged HIGH alerts — the only number the bell ever shows. */
  urgentCount: number;
  /** Anything unacknowledged at MEDIUM — shown as a dot, never a number. */
  hasUnreadMedium: boolean;
};

const AlertsContext = createContext<Ctx | null>(null);

export function useAlerts(): Ctx | null {
  return useContext(AlertsContext);
}

function storageKey(adminEmail: string) {
  return `h24.alerts.ack.v1:${adminEmail.toLowerCase()}`;
}

function readAcks(key: string): Record<string, string> {
  try {
    const raw = window.localStorage.getItem(key);
    const parsed = raw ? JSON.parse(raw) : {};
    return parsed && typeof parsed === "object" ? (parsed as Record<string, string>) : {};
  } catch {
    return {};
  }
}

function writeAcks(key: string, value: Record<string, string>) {
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch {
    /* private mode / quota — acknowledgements are a convenience */
  }
}

export default function AlertsProvider({
  enabled,
  adminEmail,
  children,
}: {
  enabled: boolean;
  adminEmail: string | null;
  children: React.ReactNode;
}) {
  const [state, setState] = useState<State>({ data: null, error: null, loading: false, fetchedAt: null });
  const [acks, setAcks] = useState<Record<string, string>>({});
  const inFlight = useRef<AbortController | null>(null);
  const fetchedAtRef = useRef<number | null>(null);
  const key = adminEmail ? storageKey(adminEmail) : null;

  useEffect(() => {
    if (key) setAcks(readAcks(key));
  }, [key]);

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

  // Forget acknowledgements for alerts that no longer exist, so a condition
  // that clears and later recurs is raised afresh.
  useEffect(() => {
    if (!key || !state.data) return;
    const live = new Set(state.data.alerts.map((a) => a.id));
    const pruned = Object.fromEntries(Object.entries(acks).filter(([id]) => live.has(id)));
    if (Object.keys(pruned).length !== Object.keys(acks).length) {
      setAcks(pruned);
      writeAcks(key, pruned);
    }
  }, [state.data, acks, key]);

  const isAcknowledged = useCallback((a: AdminAlert) => acks[a.id] === a.fingerprint, [acks]);

  const setAck = useCallback(
    (a: AdminAlert, on: boolean) => {
      if (!key) return;
      setAcks((prev) => {
        const next = { ...prev };
        if (on) next[a.id] = a.fingerprint;
        else delete next[a.id];
        writeAcks(key, next);
        return next;
      });
    },
    [key],
  );

  const value = useMemo<Ctx>(() => {
    const alerts = state.data?.alerts ?? [];
    const open = alerts.filter((a) => acks[a.id] !== a.fingerprint);
    return {
      ...state,
      enabled,
      refresh: () => void load(),
      isAcknowledged,
      acknowledge: (a) => setAck(a, true),
      unacknowledge: (a) => setAck(a, false),
      urgentCount: open.filter((a) => a.priority === "high").length,
      hasUnreadMedium: open.some((a) => a.priority === "medium"),
    };
  }, [state, enabled, load, isAcknowledged, setAck, acks]);

  return <AlertsContext.Provider value={value}>{children}</AlertsContext.Provider>;
}
