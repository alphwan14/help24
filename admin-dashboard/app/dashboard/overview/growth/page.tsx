import { growth, pct, durationText } from "@/lib/analytics";
import { slotsFor } from "@/lib/periods";
import {
  periodFor,
  readActiveDays,
  readApplications,
  readNewMembers,
  readPosts,
  readTransactions,
  settle,
} from "@/lib/market-data";
import { Panel, Stat } from "@/components/analytics/Stat";
import TrendColumns from "@/components/analytics/TrendColumns";
import { ReadFailed, TabToolbar, perBucket } from "@/components/analytics/TabToolbar";

// Rendered per request (lib/route-freshness.test.mjs).
export const dynamic = "force-dynamic";

const n = (x: number) => Math.round(x).toLocaleString("en-KE");

/**
 * Is Help24 growing, and is the marketplace working?
 *
 * Two kinds of growth: people (new members, new providers, how many come
 * back) and liquidity (requests that get answered, hired and paid). The
 * funnel is the heart of it: a marketplace grows when requests turn into
 * paid jobs, not when signups do.
 */
export default async function GrowthPage({ searchParams }: { searchParams: Promise<{ period?: string }> }) {
  const period = await periodFor(searchParams);
  const slots = slotsFor(period);
  const read = await settle(async () => {
    const [users, active, posts, apps, tx] = await Promise.all([
      readNewMembers(period),
      readActiveDays(period),
      readPosts(period, "id, created_at, type, category, status, selected_provider_id"),
      readApplications(period),
      readTransactions(period),
    ]);
    return growth(users, active, posts, apps, tx, period, slots);
  });

  return (
    <div>
      <TabToolbar title="Growth" sub={`People and marketplace activity, against ${period.versus}`} period={period} />
      {!read.ok ? <ReadFailed what="growth figures" error={read.error} /> : <GrowthView g={read.data} slots={slots} bucket={perBucket(period)} />}
    </div>
  );
}

function GrowthView({ g, slots, bucket }: { g: ReturnType<typeof growth>; slots: ReturnType<typeof slotsFor>; bucket: string }) {
  const col = (data: Array<{ values: number[]; previous: number }>) =>
    slots.map((s, i) => ({ label: s.label, short: s.short, future: s.future, values: data[i].values, previous: data[i].previous }));

  const steps = [
    { label: "Requests posted", value: g.requests.now },
    { label: "Got a response", value: g.responded.now },
    { label: "Provider hired", value: g.hired.now },
    { label: "Paid through Help24", value: g.paid.now },
  ];
  const max = Math.max(1, steps[0].value);

  return (
    <div className="space-y-5">
      <div>
        <p className="text-[12px] font-semibold text-gray-500 mb-2.5">People</p>
        <div className="grid grid-cols-2 gap-2.5 sm:gap-4 lg:grid-cols-4">
          <Stat label="New members" value={n(g.members.now)} current={g.members.now} previous={g.members.before} />
          <Stat label="New providers" value={n(g.providers.now)} current={g.providers.now} previous={g.providers.before} sub="Joined with a profession" />
          <Stat label="Active members" value={n(g.active.now)} current={g.active.now} previous={g.active.before} sub="Opened the app in the period" />
          <Stat label="Active on an average day" value={g.avgDaily < 10 ? g.avgDaily.toFixed(1) : n(g.avgDaily)} sub="Members a day" />
        </div>
      </div>

      <div>
        <p className="text-[12px] font-semibold text-gray-500 mb-2.5">Marketplace</p>
        <div className="grid grid-cols-2 gap-2.5 sm:gap-4 lg:grid-cols-4">
          <Stat label="Requests" value={n(g.requests.now)} current={g.requests.now} previous={g.requests.before} />
          <Stat label="Offers" value={n(g.offers.now)} current={g.offers.now} previous={g.offers.before} />
          <Stat
            label="Response rate"
            value={pct(g.responseRate.now)}
            current={g.responseRate.now}
            previous={g.responseRate.before}
            previousText={pct(g.responseRate.before)}
            sub="Requests with an answer"
          />
          <Stat label="First response" value={durationText(g.medianWaitMs)} sub="Median wait for an answer" />
        </div>
      </div>

      <div className="grid grid-cols-1 gap-5 lg:grid-cols-5">
        <Panel className="lg:col-span-2" title="From request to paid job" sub="Requests posted in the period, and how far they got">
          <ol className="space-y-3.5">
            {steps.map((s, i) => {
              const prev = i > 0 ? steps[i - 1].value : null;
              return (
                <li key={s.label}>
                  <div className="flex items-baseline justify-between gap-3 text-[13px]">
                    <span className="text-gray-700">{s.label}</span>
                    <span className="tabular-nums">
                      <span className="font-semibold text-gray-900">{n(s.value)}</span>
                      {prev != null && (
                        <span className="ml-2 text-[11.5px] text-gray-400">{prev > 0 ? pct(s.value / prev) : "0%"} of above</span>
                      )}
                    </span>
                  </div>
                  <div className="mt-1.5 h-2.5 rounded-full bg-gray-100 overflow-hidden">
                    <div className="h-full rounded-full bg-brand-600" style={{ width: `${s.value > 0 ? Math.max(2, (s.value / max) * 100) : 0}%`, opacity: 1 - i * 0.18 }} />
                  </div>
                </li>
              );
            })}
          </ol>
          <p className="mt-4 text-[12px] text-gray-500">
            Hire rate {pct(g.hireRate.now)}
            {g.requests.before > 0 && <> (was {pct(g.hireRate.before)})</>}
          </p>
        </Panel>

        <Panel className="lg:col-span-3" title={`New members ${bucket}`} sub={`${n(g.members.now)} joined, ${n(g.providers.now)} of them as providers`}>
          <TrendColumns columns={col(g.signups)} series={[{ key: "members", label: "New members", className: "bg-info-500" }]} />
        </Panel>
      </div>

      <Panel title={`Requests and offers ${bucket}`} sub="Demand (requests) and supply (offers) posted">
        <TrendColumns
          columns={col(g.postsDaily)}
          series={[
            { key: "requests", label: "Requests", className: "bg-info-500" },
            { key: "offers", label: "Offers", className: "bg-caution-500" },
          ]}
        />
      </Panel>

      <Panel title="Demand by category" sub="Requests in the period, and how many were answered and hired">
        {g.categories.length === 0 ? (
          <p className="text-[13px] text-gray-500 py-4">No requests in this period.</p>
        ) : (
          <ul className="divide-y divide-gray-100">
            {g.categories.slice(0, 12).map((c) => (
              <li key={c.category} className="py-2.5 grid grid-cols-[1fr_auto] gap-x-4 gap-y-1.5 items-center text-[13px]">
                <span className="text-gray-800 truncate">{c.category}</span>
                <span className="tabular-nums text-gray-500 text-right">
                  <span className="font-semibold text-gray-900">{n(c.requests)}</span> requests
                  <span className="mx-1.5 text-gray-300" aria-hidden>|</span>
                  {n(c.hired)} hired
                </span>
                <div className="col-span-2 flex items-center gap-2">
                  <div className="h-1.5 flex-1 rounded-full bg-gray-100 overflow-hidden">
                    <div
                      className={["h-full rounded-full", c.responseRate >= 0.5 ? "bg-positive-500" : c.responseRate > 0 ? "bg-caution-500" : "bg-critical-500"].join(" ")}
                      style={{ width: `${Math.max(2, c.responseRate * 100)}%` }}
                    />
                  </div>
                  <span className="w-[86px] text-right text-[11.5px] text-gray-500 tabular-nums">{pct(c.responseRate)} answered</span>
                </div>
              </li>
            ))}
          </ul>
        )}
      </Panel>
    </div>
  );
}
