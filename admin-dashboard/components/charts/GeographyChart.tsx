"use client";

import { BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from "recharts";
import { CHART } from "@/lib/tokens";

export interface GeoPoint { city: string; count: number; pct: number }

/*
 * ONE HUE, NOT A RAMP BY RANK.
 *
 * This was a six-step violet ramp assigned by row order and cycled with
 * `i % BAR_COLORS.length`. Two things were wrong with that: colouring nominal
 * bars by their value spends the identity channel re-encoding what bar length
 * already shows, and cycling means a city changes colour when the row count
 * changes — so the same place is violet in one view and lilac in the next.
 *
 * Cities are nominal and there is one series, so there is one colour and the
 * title says what it is.
 */

export function GeographyChart({ data }: { data: GeoPoint[] }) {
  return (
    <ResponsiveContainer width="100%" height={Math.max(200, data.length * 40)}>
      <BarChart data={data} layout="vertical" margin={{ top: 4, right: 48, left: 16, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke={CHART.grid} horizontal={false} />
        <XAxis type="number" tick={{ fontSize: 11, fill: CHART.labelMuted }} tickLine={false} axisLine={false} allowDecimals={false} />
        <YAxis type="category" dataKey="city" tick={{ fontSize: 12, fill: CHART.label }} tickLine={false} axisLine={false} width={80} />
        <Tooltip
          formatter={(v: number, _: string, props: { payload?: GeoPoint }) => [
            `${v} posts (${props.payload?.pct ?? 0}%)`,
            "Activity",
          ]}
          contentStyle={{ fontSize: 12, borderRadius: 8, border: `1px solid ` }}
        />
        <Bar dataKey="count" radius={[0, 4, 4, 0]} fill={CHART.series[0]} maxBarSize={22}>
</Bar>
      </BarChart>
    </ResponsiveContainer>
  );
}
