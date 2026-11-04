import { after, NextResponse, type NextRequest } from "next/server";
import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";
import { createServiceClient } from "@/lib/supabase-server";
import { recoveryRedirectUrl } from "@/lib/recovery-session";

export const dynamic = "force-dynamic";

/** Per caller, per server instance: enough for a person, a nuisance for a script. */
const WINDOW_MS = 10 * 60 * 1000;
const MAX_REQUESTS = 10;
const recent = new Map<string, number[]>();

function tooMany(key: string, now: number): boolean {
  const hits = (recent.get(key) ?? []).filter((t) => now - t < WINDOW_MS);
  hits.push(now);
  recent.set(key, hits);
  if (recent.size > 5000) recent.clear();
  return hits.length > MAX_REQUESTS;
}

/** Every answer takes at least this long, plus a random slice of JITTER_MS. */
const FLOOR_MS = 700;
const JITTER_MS = 400;

const RECOVER_PATH = "/auth/v1/recover";

/**
 * POST /api/admin/password-reset { email } → { ok: true }
 *
 * "Forgot password" for the admin console. The SERVER decides whether the
 * address gets an email — only an active admin_users row does — and the
 * caller can never tell which way it went: every valid address gets the same
 * body, the same cookie and, give or take the padding, the same timing.
 * Telling a stranger whether an address is an admin's would be a privacy
 * breach (the owner's call, 2026-11-04).
 *
 * How the answers are made identical: the reset runs through Supabase's own
 * client for EVERY address, so the PKCE verifier cookie — what ties a link to
 * the browser that asked — is written the same way each time. The client's
 * call to the provider's /recover is intercepted and answered at once with
 * what the provider would say. For an admin, the real call (which sends the
 * email) then runs after the response has gone, via after(); for anyone
 * else it never runs. A failure of that real call is logged, never returned:
 * returning it would say "this address is an admin's".
 *
 * The link still only works in this browser: the verifier cookie set here is
 * the one /auth/callback exchanges the code with.
 */
export async function POST(request: NextRequest) {
  const started = Date.now();
  const body = (await request.json().catch(() => null)) as { email?: unknown } | null;
  const email = typeof body?.email === "string" ? body.email.trim().toLowerCase() : "";
  if (!email || email.length > 320 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return NextResponse.json({ message: "Enter a valid email address." }, { status: 400 });
  }

  const ip = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || "unknown";
  if (tooMany(ip, started)) {
    return NextResponse.json({ message: "Too many attempts. Wait a few minutes, then try again." }, { status: 429 });
  }

  const { data, error } = await createServiceClient()
    .from("admin_users")
    .select("id")
    .eq("email", email)
    .eq("active", true)
    .limit(1);
  if (error) {
    // Says nothing about the address: the lookup failed for everyone.
    console.error("[password-reset] admin lookup failed:", error.message);
    return NextResponse.json({ message: "We couldn't send the reset email just now. Try again." }, { status: 503 });
  }
  const isAdmin = (data ?? []).length > 0;

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
        if (isAdmin) deferred.push(() => sendForReal(input, init));
        // The provider's own answer to /recover, for every address.
        return new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });
      },
    },
  });
  await supabase.auth.resetPasswordForEmail(email, { redirectTo: recoveryRedirectUrl(request.nextUrl.origin) });
  for (const send of deferred) after(send);

  const wait = started + FLOOR_MS + Math.random() * JITTER_MS - Date.now();
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
  return NextResponse.json({ ok: true }, { headers: { "Cache-Control": "no-store" } });
}

/** The real /recover. Its outcome is only ever logged — status and code, no address. */
async function sendForReal(input: RequestInfo | URL, init?: RequestInit): Promise<void> {
  try {
    const res = await fetch(input, init);
    if (!res.ok) {
      const code = ((await res.json().catch(() => ({}))) as { error_code?: string; code?: string }).error_code;
      console.error(`[password-reset] provider refused the reset email: ${res.status} ${code ?? ""}`.trim());
    }
  } catch (e) {
    console.error("[password-reset] provider unreachable:", e instanceof Error ? e.message : String(e));
  }
}
