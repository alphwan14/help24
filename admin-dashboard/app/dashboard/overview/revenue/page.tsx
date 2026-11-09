import { fmtKes } from "@/lib/post-display";
import { revenue, pct } from "@/lib/analytics";
import { slotsFor } from "@/lib/periods";
import { periodFor, readCategories, readPromotionSales, readTransactions, settle } from "@/lib/market-data";
import { Panel, Stat } from "@/components/analytics/Stat";
import TrendColumns from "@/components/analytics/TrendColumns";
import { ReadFailed, TabToolbar, perBucket } from "@/components/analytics/TabToolbar";

// Rendered per request: figures on a payments console must be fresh
// (lib/route-freshness.test.mjs).
export const dynamic = "force-dynamic";

const n = (x: number) => Math.round(x).toLocaleString("en-KE");

/**
 * How the marketplace is earning, for any period from today to a year.
 *
 * Earnings first (what Help24 keeps), then the money it comes from (payments
 * volume, take rate, average job), then where it comes from (by day, by
 * category) and where the rest goes (to providers).
 */
export default async function RevenuePage({ searchParams }: { searchParams: Promise<{ period?: string }> }) {
  const period = await periodFor(searchParams);
  const slots = slotsFor(period);
  const read = await settle(async () => {
    const [tx, promos] = await Promise.all([readTransactions(period), readPromotionSales(period)]);
    const cats = await readCategories(tx.filter((r) => r.post_id).map((r) => r.post_id as string));
    return revenue(tx, promos, cats, period, slots);
  });

  return (
    <div>
      <TabToolbar title="Revenue" sub={`How the marketplace is earning, against ${period.versus}`} period={period} />
      {!read.ok ? (
        <ReadFailed what="revenue" error={read.error} />
      ) : (
        <RevenueView r={read.data} slots={slots} bucket={perBucket(period)} />
      )}
    </div>
  );
}

function RevenueView({
  r,
  slots,
  bucket,
}: {
  r: ReturnType<typeof revenue>;
  slots: ReturnType<typeof slotsFor>;
  bucket: string;
}) {
  const columns = slots.map((s, i) => ({ label: s.label, short: s.short, future: s.future, values: r.daily[i].values, previous: r.daily[i].previous }));
  const feesShare = r.volume.now > 0 ? r.fees.now / r.volume.now : 0;

  return (
    <div className="space-y-5">
      {/* Earnings, and the money behind it */}
      <div className="grid grid-cols-2 gap-2.5 sm:gap-4 lg:grid-cols-4">
        <Stat className="col-span-2 lg:col-span-1" label="Earnings" value={fmtKes(r.earnings.now)} current={r.earnings.now} previous={r.earnings.before} previousText={fmtKes(r.earnings.before)} />
        <Stat label="Job fees" value={fmtKes(r.fees.now)} current={r.fees.now} previous={r.fees.before} />
        <Stat label="Promotion sales" value={fmtKes(r.sales.now)} current={r.sales.now} previous={r.sales.before} />
        <Stat label="Payments volume" value={fmtKes(r.volume.now)} current={r.volume.now} previous={r.volume.before} sub="Paid by customers" />
        <Stat label="Paid jobs" value={n(r.paidJobs.now)} current={r.paidJobs.now} previous={r.paidJobs.before} />
        <Stat label="Average job" value={fmtKes(r.avgJob.now)} current={r.avgJob.now} previous={r.avgJob.before} />
        <Stat label="Take rate" value={pct(r.takeRate.now)} current={r.takeRate.now} previous={r.takeRate.before} previousText={pct(r.takeRate.before)} sub="Fees as a share of volume" />
        <Stat
          label="Lost at checkout"
          value={fmtKes(r.failed.now)}
          current={r.failed.now}
          previous={r.failed.before}
          better="down"
          sub={`${n(r.failedCount.now)} failed payments`}
        />
      </div>

      <Panel
        title={`Revenue ${bucket}`}
        sub={
          r.best
            ? `Best: ${slots[r.best.index].label}, ${fmtKes(r.best.value)}`
            : "No earnings in this period yet"
        }
      >
        <TrendColumns
          money
          columns={columns}
          series={[
            { key: "fees", label: "Job fees", className: "bg-brand-600" },
            { key: "promos", label: "Promotions", className: "bg-accent-500" },
          ]}
        />
      </Panel>

      <div className="grid grid-cols-1 gap-5 lg:grid-cols-5">
        <Panel className="lg:col-span-3" title="Earnings by category" sub="Job fees on paid jobs, by the category of the job">
          {r.categories.length === 0 ? (
            <p className="text-[13px] text-gray-500 py-4">No paid jobs in this period.</p>
          ) : (
            <ul className="divide-y divide-gray-100">
              <li className="hidden sm:grid grid-cols-[1fr_70px_110px_96px] gap-3 pb-2 text-[11.5px] font-medium text-gray-400">
                <span>Category</span>
                <span className="text-right">Jobs</span>
                <span className="text-right">Volume</span>
                <span className="text-right">Fees</span>
              </li>
              {r.categories.slice(0, 10).map((c) => (
                <li key={c.category} className="py-2.5">
                  <div className="grid grid-cols-[1fr_auto] sm:grid-cols-[1fr_70px_110px_96px] gap-x-3 items-baseline text-[13px]">
                    <span className="text-gray-800 truncate">{c.category}</span>
                    <span className="hidden sm:block text-right tabular-nums text-gray-600">{n(c.jobs)}</span>
                    <span className="hidden sm:block text-right tabular-nums text-gray-600">{fmtKes(c.volume)}</span>
                    <span className="text-right tabular-nums font-semibold text-gray-900">{fmtKes(c.fees)}</span>
                  </div>
                  <div className="mt-1.5 flex items-center gap-2">
                    <div className="h-1.5 flex-1 rounded-full bg-gray-100 overflow-hidden">
                      <div className="h-full rounded-full bg-brand-600" style={{ width: `${Math.max(2, c.share * 100)}%` }} />
                    </div>
                    <span className="w-9 text-right text-[11px] text-gray-400 tabular-nums">{pct(c.share)}</span>
                  </div>
                  <p className="sm:hidden mt-1 text-[11.5px] text-gray-400 tabular-nums">
                    {n(c.jobs)} jobs, {fmtKes(c.volume)} volume
                  </p>
                </li>
              ))}
            </ul>
          )}
        </Panel>

        <Panel className="lg:col-span-2" title="Where the money goes" sub="Of every payment for a job">
          {r.volume.now === 0 ? (
            <p className="text-[13px] text-gray-500 py-4">No paid jobs in this period.</p>
          ) : (
            <div>
              <div className="flex h-9 w-full overflow-hidden rounded-lg">
                <div className="bg-gray-300 flex items-center px-2.5 text-[11.5px] font-medium text-gray-800 min-w-0" style={{ width: `${(1 - feesShare) * 100}%` }}>
                  <span className="truncate">Providers</span>
                </div>
                <div className="bg-brand-600 flex items-center justify-center text-[11.5px] font-semibold text-on-action" style={{ width: `${Math.max(feesShare * 100, 9)}%` }}>
                  {pct(feesShare)}
                </div>
              </div>
              <dl className="mt-4 space-y-2.5 text-[13px]">
                <Row label="Paid by customers" value={fmtKes(r.volume.now)} strong />
                <Row label="To providers" value={fmtKes(r.payouts.now)} />
                <Row label="Help24 job fees" value={fmtKes(r.fees.now)} />
                <Row label="Plus promotion sales" value={fmtKes(r.sales.now)} />
                <div className="border-t border-gray-200 pt-2.5">
                  <Row label="Help24 earnings" value={fmtKes(r.earnings.now)} strong />
                </div>
              </dl>
              <p className="mt-3 text-[11.5px] text-gray-400">Before M-Pesa charges, which Help24 does not record yet.</p>
            </div>
          )}
        </Panel>
      </div>
    </div>
  );
}

function Row({ label, value, strong = false }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className={strong ? "font-medium text-gray-900" : "text-gray-500"}>{label}</dt>
      <dd className={["tabular-nums", strong ? "font-semibold text-gray-900" : "text-gray-700"].join(" ")}>{value}</dd>
    </div>
  );
}
