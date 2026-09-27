import RestrictedList from "@/components/moderation/RestrictedList";

export const dynamic = "force-dynamic";

export default function BannedPage() {
  return (
    <RestrictedList
      kinds={["ban"]}
      intro="Permanently banned accounts. Nothing about them is deleted; only a super admin can lift a ban, from the account."
      empty={{ title: "No banned accounts", body: "Nobody is banned." }}
    />
  );
}
