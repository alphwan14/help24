"use client";

import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from "recharts";
import { CHART } from "@/lib/tokens";

export interface CategoryPoint { category: string; count: number }

/*
 * ONE HUE. Ten hues cycled by row index was the identity channel doing no
 * work: categories are nominal, the bar length already carries the value, and
 * a category's colour changed whenever the list length did. See GeographyChart
 * for the same fix and the same reasoning.
 */

export function CategoryChart({ data }: { data: CategoryPoint[] }) {
  return (
    <ResponsiveContainer width="100%" height={Math.max(200, data.length * 36)}>
      <BarChart data={data} layout="vertical" margin={{ top: 4, right: 32, left: 16, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke={CHART.grid} horizontal={false} />
        <XAxis type="number" tick={{ fontSize: 11, fill: CHART.labelMuted }} tickLine={false} axisLine={false} allowDecimals={false} />
        <YAxis type="category" dataKey="category" tick={{ fontSize: 12, fill: CHART.label }} tickLine={false} axisLine={false} width={90} />
        <Tooltip
          formatter={(v: number) => [v, "Posts"]}
          contentStyle={{ fontSize: 12, borderRadius: 8, border: `1px solid ` }}
        />
        <Bar dataKey="count" radius={[0, 4, 4, 0]} fill={CHART.series[0]} maxBarSize={22}>
</Bar>
      </BarChart>
    </ResponsiveContainer>
  );
}
