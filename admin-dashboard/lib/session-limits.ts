// How long an admin stays signed in to the console.
//
// Supabase sign-ins never expire on their own (a refresh token lasts until it
// is used or revoked), and the console quietly renews its own admin cookie
// from that sign-in, so before these limits an admin stayed signed in for
// good. Two limits, enforced by the console itself:
//
//   ABSOLUTE: 12 hours after signing in, sign in again. Checked by middleware
//             on every page, from the time inside the session's own token.
//   IDLE:     30 minutes with no activity in any console tab, and the console
//             signs out (components/AdminShell.tsx).
//
// Pure: no server or browser imports, so node --test checks it directly.

export const ABSOLUTE_LIMIT_MS = 12 * 60 * 60 * 1000;
export const IDLE_LIMIT_MS = 30 * 60 * 1000;

/** Shared by every console tab: the last time anyone touched any of them. */
export const ACTIVE_AT_KEY = "h24_admin_active_at";

/**
 * When the person behind this Supabase access token actually signed in, in
 * milliseconds. Supabase keeps the authentication times in the token's `amr`
 * claim across refreshes; the newest one is the latest sign-in (a password
 * reset or a Google sign-in counts). Null when the token carries none.
 */
export function signedInAt(accessToken: string | null | undefined): number | null {
  if (!accessToken) return null;
  try {
    const part = accessToken.split(".")[1];
    const json = atob(part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "="));
    const payload = JSON.parse(json) as { amr?: Array<{ timestamp?: unknown }> };
    const times = (payload.amr ?? []).map((a) => a?.timestamp).filter((t): t is number => typeof t === "number" && t > 0);
    return times.length ? Math.max(...times) * 1000 : null;
  } catch {
    return null;
  }
}

/** Past the 12-hour limit? Unknown sign-in time is not treated as expired. */
export function pastAbsoluteLimit(signedIn: number | null, now = Date.now()): boolean {
  return signedIn != null && now - signedIn > ABSOLUTE_LIMIT_MS;
}

/**
 * Idle too long? Activity counts from the later of the last touch and the
 * sign-in itself, so a fresh sign-in is never mistaken for yesterday's idle tab.
 */
export function pastIdleLimit(lastActive: number | null, signedIn: number | null, now = Date.now()): boolean {
  const since = Math.max(lastActive ?? 0, signedIn ?? 0);
  return since > 0 && now - since > IDLE_LIMIT_MS;
}
