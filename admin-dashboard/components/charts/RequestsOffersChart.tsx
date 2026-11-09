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

/**
 * One stacked column per day (requests below, offers above). Side by side,
 * thirty days of two series left each bar a hairline on a phone; stacked,
 * a day is one readable column and its height is the day's posts.
 */
export function RequestsOffersChart({ data }: { data: ActivityPoint[] }) {
  return (
    <ResponsiveContainer width="100%" height="100%">
      <BarChart data={data} margin={{ top: 8, right: 8, left: -8, bottom: 0 }} barCategoryGap="22%">
        <CartesianGrid strokeDasharray="3 3" stroke={CHART.grid} vertical={false} />
        <XAxis
          dataKey="date"
          tick={{ fontSize: 11, fill: CHART.labelMuted }}
          tickLine={false}
          axisLine={false}
          interval="preserveStartEnd"
          minTickGap={18}
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
            border: `1px solid ${CHART.grid}`,
            background: CHART.surface,
            color: CHART.ink,
            boxShadow: "0 4px 6px -1px rgb(0 0 0 / 0.07)",
          }}
          cursor={{ fill: CHART.hover }}
        />
        <Legend
          wrapperStyle={{ fontSize: 12, paddingTop: 12 }}
          iconType="circle"
          iconSize={8}
        />
        <Bar dataKey="requests" name="Requests" stackId="posts" fill={CHART.series[0]} maxBarSize={18} />
        <Bar dataKey="offers"   name="Offers"   stackId="posts" fill={CHART.series[1]} radius={[2, 2, 0, 0]} maxBarSize={18} />
      </BarChart>
    </ResponsiveContainer>
  );
}
