import "server-only";
import { after } from "next/server";
import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";

/**
 * "Forgot password" without telling anyone who has an account — shared by the
 * admin console (app/api/admin/password-reset) and the partner portal
 * (app/partners/actions.ts).
 *
 * The caller decides whether the address may get an email; this sends it, or
 * not, so that the caller can give every address the same answer: the reset
 * runs through Supabase's own client for EVERY address, so the PKCE verifier
 * cookie — what ties the link to the browser that asked — is written the same
 * way each time. The client's call to the provider's /recover is intercepted
 * and answered at once with what the provider would say. For an eligible
 * address the real call (which sends the email) runs after the response has
 * gone, via after(); otherwise it never runs. A failure of that real call is
 * logged, never returned: returning it would say "this address has an
 * account". Every request then takes at least FLOOR_MS plus jitter.
 *
 * Telling a stranger whether an address has an account would be a privacy
 * breach (the owner's call, 2026-11-04).
 */

/** Per caller, per server instance: enough for a person, a nuisance for a script. */
const WINDOW_MS = 10 * 60 * 1000;
const MAX_REQUESTS = 10;
const recent = new Map<string, number[]>();

/** True once `key` has asked more than MAX_REQUESTS times in WINDOW_MS. */
export function tooManyResetRequests(key: string, now: number): boolean {
  const hits = (recent.get(key) ?? []).filter((t) => now - t < WINDOW_MS);
  hits.push(now);
  recent.set(key, hits);
  if (recent.size > 5000) recent.clear();
  return hits.length > MAX_REQUESTS;
}

/** A shape check only: never a lookup, so it says nothing about accounts. */
export function plausibleEmail(value: unknown): string | null {
  const email = typeof value === "string" ? value.trim().toLowerCase() : "";
  return email && email.length <= 320 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ? email : null;
}

/** Every answer takes at least this long, plus a random slice of JITTER_MS. */
const FLOOR_MS = 700;
const JITTER_MS = 400;

const RECOVER_PATH = "/auth/v1/recover";

/**
 * Send the reset email only if `eligible`, in a way the caller cannot tell
 * apart. `redirectTo` is the /auth/callback of the host that asked — it must
 * be in Supabase's Redirect URLs, or Supabase sends the Site URL instead.
 */
export async function sendResetUniformly(opts: {
  email: string;
  eligible: boolean;
  redirectTo: string;
  started: number;
}): Promise<void> {
  const store = await cookies();
  const deferred: Array<() => Promise<void>> = [];
  const supabase = createServerClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
    cookies: {
      getAll: () => store.getAll(),
      setAll: (list) => list.forEach(({ name, value, options }) => store.set(name, value, options)),
    },
    global: {
      fetch: async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
        if (!new URL(url).pathname.endsWith(RECOVER_PATH)) return fetch(input, init);
        if (opts.eligible) deferred.push(() => sendForReal(input, init));
        // The provider's own answer to /recover, for every address.
        return new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });
      },
    },
  });
  await supabase.auth.resetPasswordForEmail(opts.email, { redirectTo: opts.redirectTo });
  for (const send of deferred) after(send);

  const wait = opts.started + FLOOR_MS + Math.random() * JITTER_MS - Date.now();
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
}

/** The real /recover. Its outcome is only ever logged — status and code, no address. */
async function sendForReal(input: RequestInfo | URL, init?: RequestInit): Promise<void> {
  try {
    const res = await fetch(input, init);
    if (!res.ok) {
      const code = ((await res.json().catch(() => ({}))) as { error_code?: string }).error_code;
      console.error(`[password-reset] provider refused the reset email: ${res.status} ${code ?? ""}`.trim());
    }
  } catch (e) {
    console.error("[password-reset] provider unreachable:", e instanceof Error ? e.message : String(e));
  }
}
