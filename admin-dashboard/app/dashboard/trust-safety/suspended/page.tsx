import RestrictedList from "@/components/moderation/RestrictedList";

export const dynamic = "force-dynamic";

export default function SuspendedPage() {
  return (
    <RestrictedList
      kinds={["suspension"]}
      intro="Accounts suspended right now. A suspension ends on its own at the time shown; lifting it early is a senior admin decision, made from the account."
      empty={{ title: "No suspended accounts", body: "Nobody is suspended right now." }}
    />
  );
}
