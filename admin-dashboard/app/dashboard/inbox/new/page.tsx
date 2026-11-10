import NewMessageForm from "./NewMessageForm";

/** Write to a member first: a new Support conversation, sent by email. */
export default async function NewMessagePage({ searchParams }: { searchParams: Promise<{ email?: string }> }) {
  const { email } = await searchParams;
  return <NewMessageForm initialEmail={typeof email === "string" ? email.slice(0, 320) : ""} />;
}
