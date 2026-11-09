import { CHART } from "@/lib/tokens";

export interface StatusSlice {
  name: string;
  value: number;
}

/**
 * Where recent transactions stand: one stacked bar, then a row per status
 * with its count and share.
 *
 * Replaces a donut that rendered at a third of the card on a phone, whose
 * thin slices could not be told apart and whose two greys (disputed,
 * refunded) were the same colour. A labelled row per status reads at any
 * width and needs no legend.
 */
const STATUS: Record<string, { label: string; color: string; order: number }> = {
  failed: { label: "Failed", color: CHART.status.critical, order: 0 },
  disputed: { label: "Disputed", color: CHART.status.caution, order: 1 },
  pending: { label: "Awaiting payment", color: CHART.status.neutral, order: 2 },
  paid: { label: "Held in escrow", color: CHART.status.info, order: 3 },
  payout_pending: { label: "Payout pending", color: CHART.series[6], order: 4 },
  released: { label: "Paid out", color: CHART.status.positive, order: 5 },
  refunded: { label: "Refunded", color: CHART.axis, order: 6 },
};

function meta(name: string) {
  return STATUS[name] ?? { label: name.replace(/_/g, " "), color: CHART.status.neutral, order: 99 };
}

export function PaymentStatusBreakdown({ data }: { data: StatusSlice[] }) {
  const total = data.reduce((s, d) => s + d.value, 0);
  if (total === 0) return <p className="text-[13px] text-gray-500">No transactions yet.</p>;
  const rows = [...data].filter((d) => d.value > 0).sort((a, b) => meta(a.name).order - meta(b.name).order);

  return (
    <div>
      <div className="flex h-2 w-full overflow-hidden rounded-full bg-gray-100" aria-hidden>
        {rows.map((r) => (
          <span key={r.name} style={{ width: `${(r.value / total) * 100}%`, backgroundColor: meta(r.name).color }} />
        ))}
      </div>
      <ul className="mt-4 divide-y divide-gray-100">
        {rows.map((r) => {
          const m = meta(r.name);
          const pct = Math.round((r.value / total) * 100);
          return (
            <li key={r.name} className="flex items-center gap-3 py-2.5 text-[13px]">
              <span className="w-2 h-2 rounded-full shrink-0" style={{ backgroundColor: m.color }} />
              <span className="flex-1 text-gray-700">{m.label}</span>
              <span className="tabular-nums font-semibold text-gray-900">{r.value.toLocaleString("en-KE")}</span>
              <span className="tabular-nums text-gray-400 w-10 text-right">{pct}%</span>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
