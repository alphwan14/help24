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

export interface ActivityPoint { date: string; requests: number; offers: number }

export function RequestsOffersChart({ data }: { data: ActivityPoint[] }) {
  return (
    <ResponsiveContainer width="100%" height="100%">
      <BarChart data={data} margin={{ top: 8, right: 8, left: -8, bottom: 0 }} barCategoryGap="35%">
        <CartesianGrid strokeDasharray="3 3" stroke="#f1f5f9" vertical={false} />
        <XAxis
          dataKey="date"
          tick={{ fontSize: 11, fill: "#94a3b8" }}
          tickLine={false}
          axisLine={false}
          interval="preserveStartEnd"
        />
        <YAxis
          tick={{ fontSize: 11, fill: "#94a3b8" }}
          tickLine={false}
          axisLine={false}
          allowDecimals={false}
          width={28}
        />
        <Tooltip
          contentStyle={{
            fontSize: 12,
            borderRadius: 8,
            border: "1px solid #e2e8f0",
            boxShadow: "0 4px 6px -1px rgb(0 0 0 / 0.07)",
          }}
          cursor={{ fill: "#f8fafc" }}
        />
        <Legend
          wrapperStyle={{ fontSize: 12, paddingTop: 12 }}
          iconType="circle"
          iconSize={8}
        />
        <Bar dataKey="requests" name="Requests" fill="#4f46e5" radius={[3, 3, 0, 0]} maxBarSize={24} />
        <Bar dataKey="offers"   name="Offers"   fill="#a78bfa" radius={[3, 3, 0, 0]} maxBarSize={24} />
      </BarChart>
    </ResponsiveContainer>
  );
}
