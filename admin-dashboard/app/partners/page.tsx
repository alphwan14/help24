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
            {!progress.failed && summary.credited === 0 && (
              <section className="card p-5" aria-label="How it works">
                <h2 className="text-[15px] font-semibold text-gray-900">How it works</h2>
                <ol className="mt-3 space-y-2 text-[13.5px] text-gray-700 list-decimal pl-5">
                  <li>Share your code, your link or your QR code with people who need help or offer services.</li>
                  <li>
                    They download Help24 and enter your code when they set up their profile — or open your link, which fills it in.
                    They have 3 days after joining to add it.
                  </li>
                  <li>They appear in My members straight away, with what they still need to qualify.</li>
                  <li>They qualify once they use Help24 on 2 different days in their first 14, or post or send an offer.</li>
                </ol>
              </section>
            )}
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
