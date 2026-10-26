import PartnerHeader from "./PartnerHeader";
import { CodeCard, MethodSplit, SummaryTiles, WeeklyBars } from "@/components/partners/PartnerViews";
import { loadProgress } from "@/lib/partners/data";
import { requirePartner } from "@/lib/partners/identity";
import { summarise, weeklyCounts } from "@/lib/partners/rules";

// The agent's own numbers, now.
export const dynamic = "force-dynamic";

export default async function PartnerOverviewPage() {
  const agent = await requirePartner();
  const progress = agent.kind === "research" ? { data: [], failed: false } : await loadProgress(agent.id);
  const now = Date.now();
  const summary = summarise(progress.data, now);

  return (
    <>
      <PartnerHeader agent={agent} active="overview" />
      <main className="mx-auto max-w-4xl px-4 sm:px-6 py-6 space-y-5">
        <CodeCard code={agent.code} qrHref="/qr" />
        {agent.kind === "research" ? (
          <p className="card p-4 text-sm text-gray-500">
            Research views — demand by category and town, and activity trends — are being prepared and will appear here.
          </p>
        ) : (
          <>
            <SummaryTiles summary={summary} failed={progress.failed} />
            <div className="grid gap-5 lg:grid-cols-[2fr_1fr]">
              <WeeklyBars weeks={weeklyCounts(progress.data, 8, now)} />
              <MethodSplit summary={summary} />
            </div>
            <p className="text-[12px] text-gray-400">
              A member qualifies when they use Help24 on 2 different days in their first 14, or post or send an offer in that
              time, and their account is in good standing. Their sign-in is checked before payment.
            </p>
          </>
        )}
      </main>
    </>
  );
}
