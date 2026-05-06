"use client";

import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Cell } from "recharts";

export interface GeoPoint { city: string; count: number; pct: number }

const BAR_COLORS = ["#4f46e5", "#7c3aed", "#a78bfa", "#c4b5fd", "#ddd6fe", "#ede9fe"];

export function GeographyChart({ data }: { data: GeoPoint[] }) {
  return (
    <ResponsiveContainer width="100%" height={Math.max(200, data.length * 40)}>
      <BarChart data={data} layout="vertical" margin={{ top: 4, right: 48, left: 16, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#f3f4f6" horizontal={false} />
        <XAxis type="number" tick={{ fontSize: 11, fill: "#9ca3af" }} tickLine={false} axisLine={false} allowDecimals={false} />
        <YAxis type="category" dataKey="city" tick={{ fontSize: 12, fill: "#374151" }} tickLine={false} axisLine={false} width={80} />
        <Tooltip
          formatter={(v: number, _: string, props: { payload?: GeoPoint }) => [
            `${v} posts (${props.payload?.pct ?? 0}%)`,
            "Activity",
          ]}
          contentStyle={{ fontSize: 12, borderRadius: 8, border: "1px solid #e5e7eb" }}
        />
        <Bar dataKey="count" radius={[0, 4, 4, 0]}>
          {data.map((_, i) => (
            <Cell key={i} fill={BAR_COLORS[i % BAR_COLORS.length]} />
          ))}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  );
}
