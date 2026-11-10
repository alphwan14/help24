import NewMessageForm from "./NewMessageForm";

/**
 * Write to a member first, by email. `?from=security` opens it as Help24
 * Security (the Security view links here that way); otherwise Help24 Support.
 */
export default async function NewMessagePage({ searchParams }: { searchParams: Promise<{ email?: string; from?: string }> }) {
  const { email, from } = await searchParams;
  return (
    <NewMessageForm
      initialEmail={typeof email === "string" ? email.slice(0, 320) : ""}
      initialFrom={from === "security" ? "security" : "support"}
    />
  );
}
