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

// Suspending and banning moved to Trust & Safety (lib/moderation-actions.ts):
// every sanction now goes through the backend, carries a reason shown to the
// person, and is written to the append-only moderation ledger. The old
// setUserBanned flipped users.is_banned directly — migration 114 refuses that
// write, and the flag is now only a mirror of an active ban.

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
