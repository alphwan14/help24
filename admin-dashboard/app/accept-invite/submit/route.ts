import { NextResponse, type NextRequest } from "next/server";
import { publicRequest, type AcceptInviteResult } from "@/lib/api";
import { storeArbitrationToken } from "@/lib/arbitration-session";
import { requireAdminIdentity } from "@/lib/admin-identity";
import { acceptInvitation } from "@/lib/invite-acceptance";
import { isInvitedEmail } from "@/lib/invite-email-binding";
import { createSessionWriter } from "@/lib/supabase-server";
import { DASHBOARD_HOME } from "@/lib/routes";

export const dynamic = "force-dynamic";

/**
 * POST /accept-invite/submit — the invitation form's target.
 *
 * Every decision is lib/invite-acceptance.ts's; this supplies the effects and
 * answers 303, so whatever happens the browser makes an ordinary page load:
 * the dashboard, the sign-in page with a message, or the invitation again
 * with an error code. Why a plain POST rather than a Server Action is written
 * down there too.
 *
 * Same-origin only — the check Server Actions made for us: a cross-site form
 * could otherwise sign a visitor's browser into an account of the poster's
 * choosing. Middleware does not match this path; it needs no session to start.
 */
export async function POST(request: NextRequest) {
  const origin = request.headers.get("origin");
  if (origin && origin !== request.nextUrl.origin) {
    return new NextResponse("Cross-site submission refused.", { status: 403 });
  }

  const form = await request.formData();
  const field = (name: string) => String(form.get(name) ?? "");
  const token = field("token");
  // Only the address the server signed for THIS invitation may be tried on a retry.
  const claimedEmail = isInvitedEmail(token, field("email"), field("email_sig")) ? field("email") : "";

  // One session client for the whole request, so a sign-out sees the sign-in.
  const session = await createSessionWriter();

  const outcome = await acceptInvitation(
    { token, name: field("name"), password: field("password"), confirm: field("confirm"), claimedEmail },
    {
      provision: async ({ token, name, password }) => {
        const result = await publicRequest<AcceptInviteResult>("/admin/accept-invite", {
          method: "POST",
          body: JSON.stringify({ token, name, password }),
        });
        return { email: result.email, arbitrationToken: result.token };
      },
      signIn: async (email, password) => {
        const { data, error } = await session.auth.signInWithPassword({ email, password });
        return error || !data.user ? null : { userId: data.user.id };
      },
      isDashboardAdmin: async (userId) => (await requireAdminIdentity(userId)) !== null,
      signOut: async () => {
        await session.auth.signOut({ scope: "local" });
      },
      // The token lives ONLY in this httpOnly cookie — never in a response body.
      storeArbitrationToken,
    },
  );

  const to = (path: string) => NextResponse.redirect(new URL(path, request.url), 303);
  switch (outcome.kind) {
    case "dashboard":
      return to(DASHBOARD_HOME);
    case "pending-activation":
      return to("/login?message=invite-pending");
    case "sign-in":
      return to("/login?message=invite-accepted");
    case "error":
      return to(`/accept-invite?token=${encodeURIComponent(token)}&error=${outcome.code}`);
  }
}
