import { NextResponse } from "next/server";
import { isAdminEmail, recordSecurityEvent } from "@/lib/security-log";

export const dynamic = "force-dynamic";

const EMAIL = /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,63}$/;
const REASONS = new Set(["invalid_credentials", "email_not_confirmed", "rate_limited", "other"]);

/**
 * POST /api/admin/security/failed-sign-in { email, reason } → 204
 *
 * The sign-in page reports a failed password attempt here so super admins can
 * see attempts on admin accounts (Users > Security log). Supabase Auth keeps
 * no record of a wrong password, so the page is the only place that knows.
 *
 * Always 204, whatever happens: the answer must not tell anyone whether an
 * address belongs to an admin. Only attempts on real admin addresses are
 * written, so typing nonsense into the form cannot fill the log.
 */
export async function POST(request: Request) {
  try {
    const body = (await request.json()) as { email?: unknown; reason?: unknown };
    const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
    const reason = typeof body.reason === "string" && REASONS.has(body.reason) ? body.reason : "other";
    if (EMAIL.test(email) && (await isAdminEmail(email))) {
      await recordSecurityEvent(
        { event: "sign_in.failed", outcome: "failure", actorKind: "admin", email, detail: { reason, method: "password" } },
        request.headers,
      );
    }
  } catch {
    /* a malformed report is ignored */
  }
  return new NextResponse(null, { status: 204 });
}
