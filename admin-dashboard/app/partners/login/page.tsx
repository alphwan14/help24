import LoginForm from "./LoginForm";

const REASONS: Record<string, string> = {
  not_partner: "This sign-in isn't a Help24 partner account.",
  suspended: "This partner account is paused. Contact Help24 if you think that's a mistake.",
  unavailable: "We couldn't check your account just now. Please try again.",
};

export default async function PartnerLoginPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const { error } = await searchParams;
  return (
    <main className="mx-auto max-w-sm px-4 py-16">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src="/favicon.svg" alt="" className="h-12 w-12" />
      <h1 className="mt-5 text-2xl font-bold text-gray-900">Help24 Partners</h1>
      <p className="mt-1 text-sm text-gray-500">Sign in to see your agent code and the members you brought.</p>
      <LoginForm notice={error ? REASONS[error] : undefined} />
      <p className="mt-6 text-[12.5px] text-gray-400">
        New partner? Open the invitation link Help24 sent you. Forgot your password? Ask Help24 for a new invitation.
      </p>
    </main>
  );
}
