import AuthShell from "@/components/auth/AuthShell";
import { SIGN_IN_HELP } from "@/lib/auth-audiences";
import { parseRecoveryLinkError } from "@/lib/recovery-session";
import ResetPasswordFlow from "@/app/reset-password/ResetPasswordFlow";

export const dynamic = "force-dynamic";

/**
 * The partner host's /reset-password: where a partner's reset link ends up,
 * after /auth/callback traded its code for a recovery session. The same
 * screen as the admin console's (the session is read in the browser — see
 * app/reset-password/page.tsx for why), framed as Help24 Partners.
 */
export default async function PartnerResetPasswordPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const { error } = await searchParams;
  return (
    <AuthShell
      product="Help24 Partners"
      notice="Partner access is by invitation"
      help={SIGN_IN_HELP}
      title="Choose a new password"
    >
      <ResetPasswordFlow linkError={parseRecoveryLinkError(error)} audience="partner" />
    </AuthShell>
  );
}
