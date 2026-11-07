import LoginForm from "./LoginForm";

const REASONS: Record<string, string> = {
  not_partner: "This sign-in isn't a Help24 partner account.",
  suspended: "This partner account is paused. Contact Help24 if you think that's a mistake.",
  unavailable: "We couldn't check your account just now. Please try again.",
};

/** `?reset=1` (from "Request a new link" on /reset-password) opens the form in reset mode. */
export default async function PartnerLoginPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string; reset?: string }>;
}) {
  const { error, reset } = await searchParams;
  return <LoginForm notice={error ? REASONS[error] : undefined} startInReset={reset === "1"} />;
}
