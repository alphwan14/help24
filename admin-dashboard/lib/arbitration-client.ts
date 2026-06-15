"use client";

import type { AdminRole } from "./api";

export type RestoreResult = {
  connected: boolean;
  email?: string;
  name?: string;
  role?: AdminRole;
  reason?: unknown;
};

/** Resolved arbitration identity shared across the app shell and sidebar. */
export type ArbitrationIdentity = {
  connected: boolean;
  email?: string;
  name?: string;
  role?: AdminRole;
};

let inFlight: Promise<RestoreResult> | null = null;
let lastResult: RestoreResult | null = null;
let lastAt = 0;

async function doRestore(): Promise<RestoreResult> {
  try {
    const res = await fetch("/api/admin/session/restore", { method: "POST" });
    const data = (await res.json()) as RestoreResult;
    lastResult = data;
    lastAt = Date.now();
    return data;
  } catch {
    return { connected: false };
  }
}

/**
 * Silently restore arbitration access from the authenticated Supabase session.
 *
 * Deduped across components: the Sidebar identity card and a page-level access
 * gate can both ask to restore at the same time, but only ONE backend rotation
 * fires — concurrent callers share the in-flight promise, and a fresh result is
 * briefly cached. Pass force=true to bypass the cache (used right after clearing
 * a mismatched token, where a brand-new identity must be minted).
 */
export async function restoreArbitration(force = false): Promise<RestoreResult> {
  if (!force && lastResult && Date.now() - lastAt < 5000) return lastResult;
  if (!force && inFlight) return inFlight;

  const p = doRestore();
  inFlight = p;
  try {
    return await p;
  } finally {
    if (inFlight === p) inFlight = null;
  }
}
