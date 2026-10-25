import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { ADMIN_TOKEN_COOKIE } from "@/lib/api";

export const dynamic = "force-dynamic";

/**
 * DELETE /api/admin/session — drop the arbitration token cookie. Sign-out's
 * first step (components/Sidebar.tsx).
 *
 * A plain request on purpose. Sign-out used the `clearArbitrationToken` Server
 * Action, and a Server Action waits its turn in Next's client router queue:
 * with a navigation or refresh still pending there (landing on /dashboard is a
 * redirect to /dashboard/overview, and the shell refreshes after restoring
 * access), "Signing out…" could hang for good — seen in e2e/run.mjs straight
 * after signing in. A fetch goes out at once.
 *
 * Idempotent, and harmless to forge: cross-site pages cannot send DELETE
 * without a CORS preflight this route never answers, and the worst it could do
 * is sign somebody's arbitration access out.
 */
export async function DELETE() {
  (await cookies()).delete(ADMIN_TOKEN_COOKIE);
  return new NextResponse(null, { status: 204 });
}
