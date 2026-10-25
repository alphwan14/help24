import { redirect } from "next/navigation";
import { getSessionUser } from "@/lib/supabase-server";
import { requireAdminIdentity } from "@/lib/admin-identity";
import { getCurrentAdmin, type AdminRole } from "@/lib/api";
import { hasPasswordSignIn } from "@/lib/admin-password";
import ChangePasswordForm from "./ChangePasswordForm";
import RefreshWhenConnected from "./RefreshWhenConnected";
import ResetLinkRequest from "./ResetLinkRequest";

export const dynamic = "force-dynamic";

const ROLE_LABELS: Record<AdminRole, string> = {
  support_agent: "Support Agent",
  senior_admin: "Senior Admin",
  super_admin: "Super Admin",
};

const PROVIDER_LABELS: Record<string, string> = {
  email: "Email and password",
  google: "Google",
  apple: "Apple",
  phone: "Phone",
};

function fmtDateTime(iso: string | null | undefined): string {
  if (!iso) return "—";
  // Pinned to Nairobi: the server renders in UTC, and an admin reading
  // "last sign-in" wants their own clock, not the data centre's.
  return new Date(iso).toLocaleString("en-KE", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    timeZone: "Africa/Nairobi",
  });
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-1 gap-0.5 py-3 sm:grid-cols-[170px_1fr] sm:gap-4">
      <dt className="text-gray-500">{label}</dt>
      <dd className="font-medium text-gray-900 break-words">{children}</dd>
    </div>
  );
}

/**
 * The signed-in admin's own account, and the one setting it has: its password.
 *
 * Everything here describes THIS session. The account is the Supabase user the
 * provider verified from the session cookie; the name and role come from the
 * arbitration record only when that record's email is this session's email —
 * the shell already reconnects on a mismatch, and until it has, this page
 * shows less rather than somebody else's details.
 */
export default async function SettingsPage() {
  // Middleware has already admitted this request as an admin. Checked again
  // here because this page shows account details and changes a credential.
  const user = await getSessionUser();
  if (!user) redirect("/login?message=session-expired");

  const [identity, arbitration] = await Promise.all([
    requireAdminIdentity(user.id),
    getCurrentAdmin(),
  ]);
  if (!identity) redirect("/login?error=unauthorized");

  const email = user.email ?? "";
  const admin =
    arbitration && email && arbitration.email.toLowerCase() === email.toLowerCase()
      ? arbitration
      : null;
  const canChangePassword = hasPasswordSignIn(user);
  const providers = Array.from(new Set((user.identities ?? []).map((i) => i.provider)));
  const signInMethod = canChangePassword
    ? PROVIDER_LABELS.email
    : providers.map((p) => PROVIDER_LABELS[p] ?? p).join(", ") || "—";

  return (
    <div className="max-w-3xl space-y-6">
      <div className="page-header">
        <h1>Settings</h1>
        <p>Your admin account and how you sign in.</p>
      </div>

      <section aria-labelledby="account-heading" className="card p-5 sm:p-6">
        {!admin && <RefreshWhenConnected />}
        <h2 id="account-heading" className="text-base font-bold text-gray-900">
          Account
        </h2>
        <p className="mt-0.5 text-sm text-gray-500">The account you&apos;re signed in with.</p>
        <dl className="mt-3 divide-y divide-gray-100 text-sm">
          <Row label="Name">{admin?.name || "—"}</Row>
          <Row label="Email">{email || "—"}</Row>
          <Row label="Role">{admin ? (ROLE_LABELS[admin.role] ?? admin.role) : "Admin"}</Row>
          <Row label="Sign-in method">{signInMethod}</Row>
          <Row label="Last sign-in">{fmtDateTime(user.last_sign_in_at)}</Row>
        </dl>
      </section>

      <section aria-labelledby="password-heading" className="card p-5 sm:p-6">
        <h2 id="password-heading" className="text-base font-bold text-gray-900">
          Password
        </h2>
        {canChangePassword ? (
          <>
            <p className="mt-0.5 text-sm text-gray-500">
              Changing it signs this account out on every other device. You stay signed in here.
            </p>
            <ChangePasswordForm email={email} />
            <ResetLinkRequest
              email={email}
              heading="Forgot your current password?"
              action="Email me a reset link"
            />
          </>
        ) : (
          <>
            <p className="mt-0.5 text-sm text-gray-500">
              This account doesn&apos;t sign in with a password, so there isn&apos;t one to
              change here.{" "}
              {email
                ? "You can set one with a reset link, or ask a super admin for help."
                : "Ask a super admin for help."}
            </p>
            {email && (
              <ResetLinkRequest email={email} heading="Set a password" action="Email me a link to set one" />
            )}
          </>
        )}
      </section>
    </div>
  );
}
