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

/** The last confirmed identity, so the nav knows the admin's role on the first
 *  paint. Per browser; AdminShell checks it against the live answer. */
export const IDENTITY_KEY = "h24_admin_identity";

export function rememberIdentity(ident: ArbitrationIdentity) {
  try {
    if (ident.connected) localStorage.setItem(IDENTITY_KEY, JSON.stringify(ident));
    else localStorage.removeItem(IDENTITY_KEY);
  } catch {
    /* private mode: the nav waits for the live answer instead */
  }
}

async function doRestore(accessToken?: string, method?: "password" | "google"): Promise<RestoreResult> {
  try {
    // A token straight from sign-in is sent along: the session cookie it also
    // wrote may not be readable by the server yet on a slow phone.
    const res = await fetch("/api/admin/session/restore", {
      method: "POST",
      headers: {
        ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
        // How they signed in, for the security log (Users > Security log).
        ...(method ? { "X-H24-Sign-In": method } : {}),
      },
    });
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
export async function restoreArbitration(
  force = false,
  accessToken?: string,
  method?: "password" | "google",
): Promise<RestoreResult> {
  if (!force && lastResult && Date.now() - lastAt < 5000) return lastResult;
  if (!force && inFlight) return inFlight;

  const p = doRestore(accessToken, method);
  inFlight = p;
  try {
    return await p;
  } finally {
    if (inFlight === p) inFlight = null;
  }
}
