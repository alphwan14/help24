import Link from "next/link";
import { ApiError, getInvite } from "@/lib/api";
import AcceptInviteForm from "./AcceptInviteForm";

export const dynamic = "force-dynamic";

type PageProps = { searchParams: Promise<{ token?: string }> };

function Shell({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-brand-900 to-brand-700 p-4">
      <div className="w-full max-w-sm">
        <div className="text-center mb-8">
          <div className="inline-flex items-center justify-center w-14 h-14 rounded-2xl bg-white/10 mb-4">
            <span className="text-2xl font-bold text-white">H</span>
          </div>
          <h1 className="text-2xl font-bold text-white">Help24 Admin</h1>
          <p className="text-brand-200 text-sm mt-1">Accept your invitation</p>
        </div>
        {children}
      </div>
    </div>
  );
}

function ErrorCard({ message }: { message: string }) {
  const title = titleFor(message);
  return (
    <Shell>
      <div className="card p-6 text-center space-y-3">
        <div className="mx-auto w-10 h-10 rounded-full bg-red-50 border border-red-200 flex items-center justify-center text-red-600">
          {title === "Invite already completed" ? "✓" : "✕"}
        </div>
        <h2 className="text-base font-bold text-gray-900">{title}</h2>
        <p className="text-sm text-gray-700">{message}</p>
        <p className="text-xs text-gray-400">
          {title === "Invite already completed"
            ? "This invitation has been used. Just sign in below."
            : "Ask a super_admin to send you a fresh invitation."}
        </p>
        <Link href="/login" className="inline-block text-sm text-brand-600 hover:underline">
          Go to sign in →
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
  const { token } = await searchParams;

  if (!token) {
    return <ErrorCard message="This link is missing its invite token." />;
  }

  try {
    const invite = await getInvite(token);
    return (
      <Shell>
        <AcceptInviteForm
          token={token}
          email={invite.email}
          role={invite.role}
          expiresAt={invite.expires_at}
        />
      </Shell>
    );
  } catch (err) {
    const message =
      err instanceof ApiError
        ? err.message
        : "This invitation could not be loaded. It may have expired.";
    return <ErrorCard message={message} />;
  }
}
