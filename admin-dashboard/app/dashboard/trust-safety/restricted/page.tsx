import RestrictedList from "@/components/moderation/RestrictedList";

export const dynamic = "force-dynamic";

export default function RestrictedPage() {
  return (
    <RestrictedList
      kinds={["messaging", "marketplace"]}
      intro="Accounts with a partial restriction: they can use Help24, but not message, or not post, apply, hire, pay or promote."
      empty={{ title: "No partial restrictions", body: "No account has a messaging or marketplace restriction." }}
    />
  );
}
