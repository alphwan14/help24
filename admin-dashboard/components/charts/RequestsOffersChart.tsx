"use client";

import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
} from "recharts";
import { CHART } from "@/lib/tokens";

export interface ActivityPoint { date: string; requests: number; offers: number }

export function RequestsOffersChart({ data }: { data: ActivityPoint[] }) {
  return (
    <ResponsiveContainer width="100%" height="100%">
      <BarChart data={data} margin={{ top: 8, right: 8, left: -8, bottom: 0 }} barCategoryGap="35%">
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
          contentStyle={{
            fontSize: 12,
            borderRadius: 8,
            border: `1px solid `,
            boxShadow: "0 4px 6px -1px rgb(0 0 0 / 0.07)",
          }}
          cursor={{ fill: CHART.hover }}
        />
        <Legend
          wrapperStyle={{ fontSize: 12, paddingTop: 12 }}
          iconType="circle"
          iconSize={8}
        />
        <Bar dataKey="requests" name="Requests" fill={CHART.series[0]} radius={[3, 3, 0, 0]} maxBarSize={24} />
        <Bar dataKey="offers"   name="Offers"   fill={CHART.series[1]} radius={[3, 3, 0, 0]} maxBarSize={24} />
      </BarChart>
    </ResponsiveContainer>
  );
}
