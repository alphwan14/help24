"use client";

import { getSupabaseBrowser } from "@/lib/supabase-browser";

/**
 * Sign out of both identities: the arbitration bearer cookie first, then the
 * Supabase session. Clearing only one leaves the other active (split brain).
 * Neither goes through Next's router, whose queued navigations once left
 * "Signing out" hanging; a full page load also drops the dashboard from memory.
 *
 * Used by Sign out in the sidebar and by the 30-minute idle limit (AdminShell),
 * which lands on the sign-in page with a reason.
 */
export async function signOutOfConsole(next = "/login") {
  try {
    // The role AdminShell remembers for a fast first paint goes with the session.
    localStorage.removeItem("h24_admin_identity");
  } catch {
    /* private mode */
  }
  try {
    await fetch("/api/admin/session", { method: "DELETE" });
  } catch {
    /* still end the Supabase session */
  }
  try {
    await getSupabaseBrowser().auth.signOut();
  } finally {
    window.location.assign(next);
  }
}
