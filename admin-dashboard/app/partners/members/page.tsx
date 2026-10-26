import { redirect } from "next/navigation";
import PartnerHeader from "../PartnerHeader";
import { ProgressList } from "@/components/partners/PartnerViews";
import { loadMemberDetails, loadProgress } from "@/lib/partners/data";
import { requirePartner } from "@/lib/partners/identity";

export const dynamic = "force-dynamic";

export default async function PartnerMembersPage() {
  const agent = await requirePartner();
  if (agent.kind === "research") redirect("/");
  const progress = await loadProgress(agent.id);
  const details = await loadMemberDetails(progress.data.map((r) => r.member_id));

  return (
    <>
      <PartnerHeader agent={agent} active="members" />
      <main className="mx-auto max-w-4xl px-4 sm:px-6 py-6 space-y-4">
        <p className="text-[13px] text-gray-500">
          Everyone credited to your code, newest first. You see each person&apos;s first name and the last digits of their
          number — enough to know who to follow up with.
        </p>
        <ProgressList rows={progress.data} details={details} masked failed={progress.failed} />
      </main>
    </>
  );
}
