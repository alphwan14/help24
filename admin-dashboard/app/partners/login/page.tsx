import AuthShell from "@/components/auth/AuthShell";
import { SIGN_IN_HELP } from "@/lib/auth-audiences";
import LoginForm from "./LoginForm";

const REASONS: Record<string, string> = {
  not_partner: "This sign-in isn't a Help24 partner account.",
  suspended: "This partner account is paused. Contact Help24 if you think that's a mistake.",
  unavailable: "We couldn't check your account just now. Please try again.",
};

export default async function PartnerLoginPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const { error } = await searchParams;
  return (
    <AuthShell
      product="Help24 Partners"
      notice="Partner access is by invitation"
      help={SIGN_IN_HELP}
      title="Sign in"
      below={<p>New, or forgot your password? Open the latest invitation Help24 sent you.</p>}
    >
      <LoginForm notice={error ? REASONS[error] : undefined} />
    </AuthShell>
  );
}
