import PeriodSelect from "@/components/analytics/PeriodSelect";
import { rangeLabel, type Period } from "@/lib/periods";

/** A tab's heading line with the period drop-down on the right. */
export function TabToolbar({ title, sub, period }: { title: string; sub: string; period: Period }) {
  return (
    <div className="flex flex-wrap items-end justify-between gap-3 mb-5">
      <div className="min-w-0">
        <h2 className="text-[17px] font-semibold text-gray-900 leading-tight">{title}</h2>
        <p className="mt-0.5 text-[13px] text-gray-500">{sub}</p>
      </div>
      <PeriodSelect value={period.key} range={rangeLabel(period)} />
    </div>
  );
}

/** A read that failed: said plainly, never drawn as zeros. */
export function ReadFailed({ what, error }: { what: string; error: string }) {
  return (
    <div className="rounded-xl border border-critical-200 bg-critical-50 p-5">
      <p className="text-sm font-semibold text-critical-700">Could not load {what}</p>
      <p className="mt-1 text-xs text-critical-600">Nothing is shown rather than figures that may be wrong. Reload to try again.</p>
      <p className="mt-2 text-[11px] font-mono text-critical-600/80 break-all">{error}</p>
    </div>
  );
}

/** "per day", "per hour", "per week", for chart titles. */
export const perBucket = (p: Period) => (p.bucket === "hour" ? "per hour" : p.bucket === "week" ? "per week" : "per day");
