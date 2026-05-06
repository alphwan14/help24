"use server";

import { createServiceClient } from "@/lib/supabase-server";
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

/** Promote or demote a user's role. All security checks run server-side. */
export async function updateUserRole(
  targetId: string,
  targetEmail: string,
  newRole: "admin" | "user"
): Promise<{ ok: true } | { ok: false; message: string }> {
  try {
    const cookieStore = await cookies();

    // Resolve the requesting admin from their session cookie
    const authClient = createServerClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
      { cookies: { getAll: () => cookieStore.getAll(), setAll: () => {} } }
    );

    const {
      data: { user: sessionUser },
    } = await authClient.auth.getUser();

    if (!sessionUser?.email) {
      return { ok: false, message: "Not authenticated." };
    }

    const db = createServiceClient();

    // Verify the requesting user is still an admin in the DB
    const { data: requester } = await db
      .from("users")
      .select("role, email")
      .eq("email", sessionUser.email)
      .maybeSingle();

    if (requester?.role !== "admin") {
      return { ok: false, message: "Insufficient permissions." };
    }

    // Self-protection — cannot demote yourself
    if (sessionUser.email.toLowerCase() === targetEmail.toLowerCase()) {
      return { ok: false, message: "You cannot change your own admin role." };
    }

    // Perform the update
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
