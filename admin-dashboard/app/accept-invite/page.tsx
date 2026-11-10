import Link from "next/link";
import { redirect } from "next/navigation";
import { ApiError, getInvite } from "@/lib/api";
import { requireAdminIdentity } from "@/lib/admin-identity";
import { inviteErrorMessage, isCompletedInvite } from "@/lib/invite-acceptance";
import { signInvitedEmail } from "@/lib/invite-email-binding";
import { getSessionUser } from "@/lib/supabase-server";
import AcceptInviteForm from "./AcceptInviteForm";
import { DASHBOARD_HOME } from "@/lib/routes";
import AuthShell from "@/components/auth/AuthShell";
import { SIGN_IN_HELP } from "@/lib/auth-audiences";

export const dynamic = "force-dynamic";

type PageProps = { searchParams: Promise<{ token?: string; error?: string }> };

/**
 * The same frame as the sign-in page (components/auth/AuthShell.tsx): the
 * Help24 mark, one card, both themes. An invitation is the first page of the
 * console a new admin sees, so it looks like the console's own front door.
 */
function Shell({ title, subtitle, children }: { title: string; subtitle?: React.ReactNode; children: React.ReactNode }) {
  return (
    <AuthShell
      product="Help24 Operations"
      title={title}
      subtitle={subtitle}
      notice="Authorised Help24 staff only"
      help={SIGN_IN_HELP}
    >
      {children}
    </AuthShell>
  );
}

function ErrorCard({ message }: { message: string }) {
  const title = titleFor(message);
  const used = title === "Invite already completed";
  return (
    <Shell title={title} subtitle={message}>
      <div className="space-y-5">
        <p className="text-[13.5px] leading-relaxed text-gray-600">
          {used ? "This invitation has been used. Sign in with the password you set." : "Ask a super admin to send you a fresh invitation."}
        </p>
        <Link href="/login" className="btn-primary w-full">
          Go to sign in
        </Link>
      </div>
    </Shell>
  );
}

/** Map a backend message to a clear, distinct UX state title. */
function titleFor(message: string): string {
  const m = message.toLowerCase();
  if (m.includes("already been completed") || m.includes("already been used"))
    return "Invite already completed";
  if (m.includes("expired")) return "Invite expired";
  if (m.includes("not found") || m.includes("invalid")) return "Invite not found";
  return "Invitation problem";
}

export default async function AcceptInvitePage({ searchParams }: PageProps) {
  const { token, error } = await searchParams;

  if (!token) {
    return <ErrorCard message="This link is missing its invite token." />;
  }

  let invite;
  try {
    invite = await getInvite(token);
  } catch (err) {
    // A used invitation opened by someone already signed in as an admin — most
    // often the invitee refreshing right after accepting. The card would tell
    // them to sign in when they already are, so take them in instead. Nothing
    // about the invitation decides this: the same check middleware makes does.
    if (err instanceof ApiError && isCompletedInvite(err)) {
      const user = await getSessionUser();
      if (user && (await requireAdminIdentity(user.id))) redirect(DASHBOARD_HOME);
    }
    const message =
      err instanceof ApiError
        ? err.message
        : "This invitation could not be loaded. It may have expired.";
    return <ErrorCard message={message} />;
  }

  return (
    <Shell title="Accept your invitation" subtitle="Set up your account to join Help24 Operations.">
      <AcceptInviteForm
        token={token}
        email={invite.email}
        emailSignature={signInvitedEmail(token, invite.email) ?? ""}
        role={invite.role}
        expiresAt={invite.expires_at}
        error={inviteErrorMessage(error)}
      />
    </Shell>
  );
}
