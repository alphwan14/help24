import Link from "next/link";
import MetricCard from "@/components/MetricCard";
import type { ModerationSummary, Settled } from "@/lib/moderation-api";

const BASE = "/dashboard/trust-safety";

/**
 * The state of the queue in one row. Tone only where the state is the point:
 * serious reports waiting is critical, nothing else is coloured.
 */
export default function SummaryStrip({ summary }: { summary: Settled<ModerationSummary> }) {
  if (!summary.ok) return null;
  const s = summary.data;
  const serious = s.critical_open + s.high_open;
  return (
    <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
      <Link href={`${BASE}/queue`} className="block rounded-xl focus:outline-none focus:ring-2 focus:ring-brand-500">
        <MetricCard label="Open reports" value={s.open_reports} sub={`${s.unassigned_open} unassigned · ${s.reports_last_24h} new today`} icon="requests" />
      </Link>
      <Link href={`${BASE}/queue?severity=critical`} className="block rounded-xl focus:outline-none focus:ring-2 focus:ring-brand-500">
        <MetricCard
          label="Critical or high, open"
          value={serious}
          sub={s.critical_open > 0 ? `${s.critical_open} critical` : "None critical"}
          accent={s.critical_open > 0 ? "critical" : serious > 0 ? "caution" : "default"}
          icon="default"
        />
      </Link>
      <Link href={`${BASE}/queue?scope=mine`} className="block rounded-xl focus:outline-none focus:ring-2 focus:ring-brand-500">
        <MetricCard label="Assigned to you" value={s.assigned_to_me} sub="Open reports you have claimed" icon="users" />
      </Link>
      <Link href={`${BASE}/suspended`} className="block rounded-xl focus:outline-none focus:ring-2 focus:ring-brand-500">
        <MetricCard
          label="Restricted accounts"
          value={s.suspended_accounts + s.banned_accounts + s.restricted_accounts}
          sub={`${s.suspended_accounts} suspended · ${s.banned_accounts} banned · ${s.restricted_accounts} partial`}
          icon="escrow"
        />
      </Link>
    </div>
  );
}
