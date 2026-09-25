"use client";

import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from "recharts";
import { CHART } from "@/lib/tokens";

export interface GrowthPoint { date: string; count: number }

export function UserGrowthChart({ data }: { data: GrowthPoint[] }) {
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
            border: `1px solid `,
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
