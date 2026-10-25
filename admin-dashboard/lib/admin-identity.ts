import { createClient } from "@supabase/supabase-js";

/**
 * The one place that answers "which Help24 person is this dashboard session,
 * and are they an admin?".
 *
 * WHY THIS EXISTS
 * The gate used to resolve admins by EMAIL: read the session user's email, look
 * up public.users by that email, trust its `role`. Two things were wrong with
 * that. First, `email` on public.users was writable by any holder of the
 * publishable key, so rewriting one string repointed the admin gate (closed by
 * migration 098). Second, and still true without this module, it conflates a
 * *login credential* with a *person* — the same conflation that let
 * `on_auth_user_created` mint marketplace identities for dashboard accounts
 * (closed by migration 099).
 *
 * The session's `user.id` IS the credential: it is `auth.users.id`, which is the
 * `subject` of a `supabase`-provider row in `user_auth_identities`. That row
 * names exactly one Help24 identity. Nothing user-writable takes part.
 *
 * NOT importable from client components, and deliberately free of any
 * `next/headers` import so Edge middleware can use it too.
 */

export type AdminIdentity = {
  /** public.users.id — the canonical Firebase-shaped Help24 identity. */
  help24UserId: string;
  /** auth.users.id — the credential that was presented. */
  authSubject: string;
  role: string;
};

/** `user_auth_identities` is RLS default-deny with the grants revoked, so the
 *  anon/session client cannot read it by design. Only service_role can. */
function identityClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return null;
  return createClient(url, key, { auth: { persistSession: false } });
}

/**
 * Why a session was not let in. Every reason DENIES; the distinction exists
 * only so the person can be told something true. "unlinked" is a correct
 * password on a login nobody has connected to a Help24 account yet — telling
 * that person "you do not have admin privileges" is what sent one admin
 * through 53 refusals and two password resets in one evening.
 */
export type AccessDenial = "unlinked" | "not_admin" | "unavailable";

export type AdminAccess =
  | { ok: true; identity: AdminIdentity }
  | { ok: false; reason: AccessDenial };

/** Same gate as resolveAdminIdentity, but says which refusal it was. */
export async function resolveAdminAccess(authSubject: string | undefined | null): Promise<AdminAccess> {
  if (!authSubject) return { ok: false, reason: "not_admin" };
  const result = await lookup(authSubject);
  if (result === "unlinked" || result === "unavailable") return { ok: false, reason: result };
  if (!result || result.role !== "admin") return { ok: false, reason: "not_admin" };
  return { ok: true, identity: result };
}

/**
 * Resolve a dashboard session to its Help24 identity and role.
 *
 * Fails CLOSED at every step — a missing service key, a query error, an
 * unlinked credential and a genuinely non-admin user all return null. A gate
 * that cannot answer must not grant.
 */
export async function resolveAdminIdentity(
  authSubject: string | undefined | null
): Promise<AdminIdentity | null> {
  if (!authSubject) return null;
  const result = await lookup(authSubject);
  return result === "unlinked" || result === "unavailable" ? null : result;
}

async function lookup(authSubject: string): Promise<AdminIdentity | "unlinked" | "unavailable" | null> {
  const db = identityClient();
  if (!db) {
    console.error("[Admin Check] SUPABASE_SERVICE_ROLE_KEY missing — denying.");
    return "unavailable";
  }

  const { data: identity, error: identityError } = await db
    .from("user_auth_identities")
    .select("help24_user_id")
    .eq("provider", "supabase")
    .eq("subject", authSubject)
    .maybeSingle();

  if (identityError) {
    console.error("[Admin Check] identity lookup failed:", identityError.message);
    return "unavailable";
  }

  // A credential nobody has linked to a person. This is the expected result for
  // a brand-new dashboard account: since migration 099 dropped
  // `on_auth_user_created`, signing up no longer creates a Help24 identity, and
  // it must not confer one either. See the admin onboarding runbook.
  if (!identity) {
    console.log(`[Admin Check] auth subject ${authSubject} is not linked to any Help24 identity.`);
    return "unlinked";
  }

  const help24UserId = identity.help24_user_id as string;

  const { data: person, error: personError } = await db
    .from("users")
    .select("role")
    .eq("id", help24UserId)
    .maybeSingle();

  if (personError) {
    console.error("[Admin Check] role lookup failed:", personError.message);
    return "unavailable";
  }

  if (!person) {
    console.error(`[Admin Check] identity ${help24UserId} has no users row — denying.`);
    return null;
  }

  return {
    help24UserId,
    authSubject,
    role: (person.role as string) ?? "user",
  };
}

/** Convenience wrapper for the common "is this session an admin?" question. */
export async function requireAdminIdentity(
  authSubject: string | undefined | null
): Promise<AdminIdentity | null> {
  const identity = await resolveAdminIdentity(authSubject);
  return identity?.role === "admin" ? identity : null;
}
