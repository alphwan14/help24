"use client";

import {
  AreaChart,
  Area,
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from "recharts";
import { CHART } from "@/lib/tokens";

export interface GrowthPoint { date: string; count: number }

/**
 * `bars` draws one column per day. For small daily counts (a few signups a
 * day, many days with none) a smoothed area invents slopes between days:
 * a single signup reads as a hill. Columns show exactly what happened.
 */
export function UserGrowthChart({ data, bars = false, name = "Signups" }: { data: GrowthPoint[]; bars?: boolean; name?: string }) {
  if (bars) {
    return (
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={data} margin={{ top: 8, right: 8, left: -8, bottom: 0 }} barCategoryGap="22%">
          <CartesianGrid strokeDasharray="3 3" stroke={CHART.grid} vertical={false} />
          <XAxis dataKey="date" tick={{ fontSize: 11, fill: CHART.labelMuted }} tickLine={false} axisLine={false} interval="preserveStartEnd" minTickGap={18} />
          <YAxis tick={{ fontSize: 11, fill: CHART.labelMuted }} tickLine={false} axisLine={false} allowDecimals={false} width={28} />
          <Tooltip
            formatter={(v: number) => [v.toLocaleString(), name]}
            contentStyle={{ fontSize: 12, borderRadius: 8, border: `1px solid ${CHART.grid}`, background: CHART.surface, color: CHART.ink }}
            cursor={{ fill: CHART.hover }}
          />
          <Bar dataKey="count" name={name} fill={CHART.series[0]} radius={[2, 2, 0, 0]} maxBarSize={18} />
        </BarChart>
      </ResponsiveContainer>
    );
  }
  return (
    <ResponsiveContainer width="100%" height="100%">
      <AreaChart data={data} margin={{ top: 8, right: 8, left: -8, bottom: 0 }}>
        <defs>
          <linearGradient id="ug-gradient" x1="0" y1="0" x2="0" y2="1">
            <stop offset="5%"  stopColor={CHART.series[0]} stopOpacity={0.12} />
            <stop offset="95%" stopColor={CHART.series[0]} stopOpacity={0} />
          </linearGradient>
        </defs>
        <CartesianGrid strokeDasharray="3 3" stroke={CHART.grid} vertical={false} />
        <XAxis
          dataKey="date"
          tick={{ fontSize: 11, fill: CHART.labelMuted }}
          tickLine={false}
          axisLine={false}
          interval="preserveStartEnd"
        />
        <YAxis
          tick={{ fontSize: 11, fill: CHART.labelMuted }}
          tickLine={false}
          axisLine={false}
          allowDecimals={false}
          width={28}
        />
        <Tooltip
          formatter={(v: number) => [v.toLocaleString(), "Count"]}
          contentStyle={{
            fontSize: 12,
            borderRadius: 8,
            border: `1px solid ${CHART.grid}`,
            background: CHART.surface,
            color: CHART.ink,
            boxShadow: "0 4px 6px -1px rgb(0 0 0 / 0.07)",
          }}
          cursor={{ stroke: CHART.grid, strokeWidth: 1 }}
        />
        <Area
          type="monotone"
          dataKey="count"
          stroke={CHART.series[0]}
          strokeWidth={2}
          fill="url(#ug-gradient)"
          dot={false}
          activeDot={{ r: 4, fill: CHART.series[0], strokeWidth: 0 }}
        />
      </AreaChart>
    </ResponsiveContainer>
  );
}
