"use server";

import { createServiceClient } from "@/lib/supabase-server";
import { requireAdminIdentity, type AdminIdentity } from "@/lib/admin-identity";
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

/** Resolve the calling admin from their session cookie, then confirm the DB
 *  still says they are an admin. Returns their Help24 identity, or an error to
 *  surface.
 *
 *  The DB is the authority, never the JWT: a session minted before a demotion
 *  would otherwise keep working until it expired.
 *
 *  Resolution goes through `user_auth_identities` keyed on the session's
 *  auth.users id — NOT through the session email. Email was a user-writable
 *  string that decided who is an admin; see lib/admin-identity.ts. */
async function requireAdmin(): Promise<
  { ok: true; identity: AdminIdentity; db: ReturnType<typeof createServiceClient> }
  | { ok: false; message: string }
> {
  const cookieStore = await cookies();

  const authClient = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { cookies: { getAll: () => cookieStore.getAll(), setAll: () => {} } }
  );

  const {
    data: { user: sessionUser },
  } = await authClient.auth.getUser();

  if (!sessionUser?.id) return { ok: false, message: "Not authenticated." };

  const identity = await requireAdminIdentity(sessionUser.id);
  if (!identity) return { ok: false, message: "Insufficient permissions." };

  return { ok: true, identity, db: createServiceClient() };
}

/** Suspend or reinstate a user.
 *
 *  This used to be a direct `update({ is_banned })` issued from the BROWSER with
 *  the visitor's own session, so the only thing standing between any holder of
 *  the publishable key and moderation state was the RLS policy on public.users —
 *  which permitted it. Banning now runs here, behind a server-side admin check,
 *  with service_role doing the write.
 *
 *  The self-suspend guard compares Help24 user ids, not emails: an id is the
 *  identity itself and cannot be restated as something else. */
export async function setUserBanned(
  targetId: string,
  banned: boolean
): Promise<{ ok: true } | { ok: false; message: string }> {
  try {
    const auth = await requireAdmin();
    if (!auth.ok) return auth;
    const { db, identity } = auth;

    // Locking yourself out is never the intent, and it is not recoverable from
    // inside the dashboard.
    if (targetId === identity.help24UserId) {
      return { ok: false, message: "You cannot suspend your own account." };
    }

    const { data: target } = await db
      .from("users")
      .select("id")
      .eq("id", targetId)
      .maybeSingle();

    if (!target) return { ok: false, message: "That user no longer exists." };

    const { error } = await db.from("users").update({ is_banned: banned }).eq("id", targetId);
    if (error) return { ok: false, message: error.message };

    return { ok: true };
  } catch (err) {
    return { ok: false, message: err instanceof Error ? err.message : "Unknown error." };
  }
}

/** Promote or demote a user's role. All security checks run server-side. */
export async function updateUserRole(
  targetId: string,
  newRole: "admin" | "user"
): Promise<{ ok: true } | { ok: false; message: string }> {
  try {
    const auth = await requireAdmin();
    if (!auth.ok) return auth;
    const { db, identity } = auth;

    // Self-protection — cannot demote yourself.
    if (targetId === identity.help24UserId) {
      return { ok: false, message: "You cannot change your own admin role." };
    }

    const { error } = await db
      .from("users")
      .update({ role: newRole })
      .eq("id", targetId);

    if (error) {
      return { ok: false, message: error.message };
    }

    return { ok: true };
  } catch (err) {
    return { ok: false, message: err instanceof Error ? err.message : "Unknown error." };
  }
}
