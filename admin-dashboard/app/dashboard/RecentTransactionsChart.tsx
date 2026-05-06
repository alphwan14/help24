"use client";

import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from "recharts";

interface TxRow {
  created_at: string;
  total_paid: number;
  status: string;
}

function buildDailyBuckets(data: TxRow[]) {
  const buckets: Record<string, { date: string; total: number; count: number }> = {};
  for (const tx of data) {
    const day = tx.created_at.slice(0, 10);
    if (!buckets[day]) buckets[day] = { date: day, total: 0, count: 0 };
    buckets[day].total += tx.total_paid ?? 0;
    buckets[day].count += 1;
  }
  return Object.values(buckets)
    .sort((a, b) => a.date.localeCompare(b.date))
    .slice(-14)
    .map((b) => ({ ...b, total: Math.round(b.total / 100) }));
}

export function RecentTransactionsChart({ data }: { data: TxRow[] }) {
  const chartData = buildDailyBuckets(data);
  return (
    <ResponsiveContainer width="100%" height={220}>
      <BarChart data={chartData} margin={{ top: 4, right: 4, left: 0, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#f3f4f6" />
        <XAxis dataKey="date" tick={{ fontSize: 11, fill: "#9ca3af" }} tickLine={false} />
        <YAxis
          tick={{ fontSize: 11, fill: "#9ca3af" }}
          tickLine={false}
          axisLine={false}
          tickFormatter={(v) => `${v}`}
        />
        <Tooltip
          formatter={(v: number) => [`KES ${v}`, "Volume"]}
          contentStyle={{ fontSize: 12, borderRadius: 8, border: "1px solid #e5e7eb" }}
        />
        <Bar dataKey="total" fill="#4f46e5" radius={[4, 4, 0, 0]} />
      </BarChart>
    </ResponsiveContainer>
  );
}
