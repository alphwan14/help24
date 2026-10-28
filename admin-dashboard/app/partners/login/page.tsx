import AuthShell from "@/components/auth/AuthShell";
import { PARTNER_AUDIENCE } from "@/lib/auth-audiences";
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
      audience={PARTNER_AUDIENCE}
      title="Welcome back"
      subtitle="Sign in to see your agent code and the members you've brought to Help24."
      below={
        <>
          <p>New partner? Open the invitation link Help24 sent you to set your password.</p>
          <p>Forgot your password? Ask Help24 for a new invitation — it lets you choose a new one.</p>
        </>
      }
    >
      <LoginForm notice={error ? REASONS[error] : undefined} />
    </AuthShell>
  );
}
