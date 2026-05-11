"use client";

import { PieChart, Pie, Cell, Tooltip, Legend, ResponsiveContainer } from "recharts";

export interface StatusSlice { name: string; value: number }

const STATUS_COLORS: Record<string, string> = {
  paid:            "#10b981",
  released:        "#059669",
  pending:         "#f59e0b",
  payout_pending:  "#3b82f6",
  failed:          "#ef4444",
};

const FALLBACK = "#94a3b8";

function StatusLabel({ name }: { name: string }) {
  return <span className="capitalize">{name.replace(/_/g, " ")}</span>;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function CustomLegend({ payload }: { payload?: any[] }) {
  if (!payload) return null;
  return (
    <ul className="flex flex-wrap justify-center gap-x-4 gap-y-1.5 mt-3">
      {payload.map((entry) => (
        <li key={entry.value} className="flex items-center gap-1.5 text-xs text-gray-600">
          <span
            className="inline-block w-2.5 h-2.5 rounded-full shrink-0"
            style={{ backgroundColor: entry.color }}
          />
          <StatusLabel name={entry.value} />
        </li>
      ))}
    </ul>
  );
}

export function PaymentStatusChart({ data }: { data: StatusSlice[] }) {
  return (
    <ResponsiveContainer width="100%" height="100%">
      <PieChart>
        <Pie
          data={data}
          dataKey="value"
          nameKey="name"
          cx="50%"
          cy="44%"
          outerRadius="38%"
          innerRadius="20%"
          paddingAngle={2}
          strokeWidth={0}
        >
          {data.map((entry) => (
            <Cell key={entry.name} fill={STATUS_COLORS[entry.name] ?? FALLBACK} />
          ))}
        </Pie>
        <Tooltip
          formatter={(v: number, name: string) => [v.toLocaleString(), name.replace(/_/g, " ")]}
          contentStyle={{
            fontSize: 12,
            borderRadius: 8,
            border: "1px solid #e2e8f0",
            boxShadow: "0 4px 6px -1px rgb(0 0 0 / 0.07)",
          }}
        />
        <Legend content={<CustomLegend />} />
      </PieChart>
    </ResponsiveContainer>
  );
}
