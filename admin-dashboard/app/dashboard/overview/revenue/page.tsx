import { createServiceClient } from "@/lib/supabase-server";
import { UserGrowthChart } from "@/components/charts/UserGrowthChart";

type TxRow = {
  created_at: string;
  total_paid: number | null;
  fee: number | null;
  status: string;
};

async function getRevenueData() {
  const db = createServiceClient();
  const since90 = new Date(Date.now() - 90 * 86400_000).toISOString();

  const { data } = await db
    .from("transactions")
    .select("created_at, total_paid, fee, status")
    .gte("created_at", since90)
    .order("created_at");

  const rows = (data ?? []) as TxRow[];

  const PAID_STATUSES = ["paid", "payout_pending", "released"];

  // Revenue by day (only paid transactions)
  const byDay: Record<string, { date: string; revenue: number; fees: number }> = {};
  for (const t of rows) {
    if (!PAID_STATUSES.includes(t.status)) continue;
    const day = t.created_at.slice(0, 10);
    byDay[day] ??= { date: day.slice(5), revenue: 0, fees: 0 };
    byDay[day].revenue += t.total_paid ?? 0;
    byDay[day].fees += t.fee ?? 0;
  }

  const revenueByDay = Object.values(byDay).sort((a, b) => a.date.localeCompare(b.date));

  // Totals
  const totalRevenue = rows
    .filter((t) => PAID_STATUSES.includes(t.status))
    .reduce((s, t) => s + (t.total_paid ?? 0), 0);

  const totalFees = rows
    .filter((t) => PAID_STATUSES.includes(t.status))
    .reduce((s, t) => s + (t.fee ?? 0), 0);

  const pendingRevenue = rows
    .filter((t) => t.status === "pending")
    .reduce((s, t) => s + (t.total_paid ?? 0), 0);

  const failedRevenue = rows
    .filter((t) => t.status === "failed")
    .reduce((s, t) => s + (t.total_paid ?? 0), 0);

  // Status breakdown counts
  const statusCounts: Record<string, number> = {};
  for (const t of rows) {
    statusCounts[t.status] = (statusCounts[t.status] ?? 0) + 1;
  }

  return { revenueByDay, totalRevenue, totalFees, pendingRevenue, failedRevenue, statusCounts, totalTx: rows.length };
}

function fmtKES(n: number) {
  return `KES ${(n / 100).toLocaleString("en-KE", { minimumFractionDigits: 0, maximumFractionDigits: 0 })}`;
}

const STATUS_COLORS: Record<string, string> = {
  pending: "bg-amber-100 text-amber-700",
  paid: "bg-green-100 text-green-700",
  failed: "bg-red-100 text-red-700",
  payout_pending: "bg-blue-100 text-blue-700",
  released: "bg-gray-100 text-gray-600",
};

export default async function RevenuePage() {
  const { revenueByDay, totalRevenue, totalFees, pendingRevenue, failedRevenue, statusCounts, totalTx } =
    await getRevenueData();

  // Convert revenue to a GrowthPoint shape for the chart (reuse LineChart)
  const chartData = revenueByDay.map((r) => ({
    date: r.date,
    count: Math.round(r.revenue / 100), // cents → KES
  }));

  return (
    <div className="space-y-6">
      {/* KPI cards */}
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <div className="card p-4">
          <p className="text-xs text-gray-500 font-medium uppercase tracking-wide mb-1">Total Revenue</p>
          <p className="text-xl font-bold text-gray-900">{fmtKES(totalRevenue)}</p>
          <p className="text-xs text-gray-400 mt-0.5">Last 90 days</p>
        </div>
        <div className="card p-4">
          <p className="text-xs text-gray-500 font-medium uppercase tracking-wide mb-1">Platform Fees</p>
          <p className="text-xl font-bold text-indigo-600">{fmtKES(totalFees)}</p>
          <p className="text-xs text-gray-400 mt-0.5">Net earned</p>
        </div>
        <div className="card p-4">
          <p className="text-xs text-gray-500 font-medium uppercase tracking-wide mb-1">Pending</p>
          <p className="text-xl font-bold text-amber-600">{fmtKES(pendingRevenue)}</p>
          <p className="text-xs text-gray-400 mt-0.5">Awaiting confirmation</p>
        </div>
        <div className="card p-4">
          <p className="text-xs text-gray-500 font-medium uppercase tracking-wide mb-1">Failed</p>
          <p className="text-xl font-bold text-red-500">{fmtKES(failedRevenue)}</p>
          <p className="text-xs text-gray-400 mt-0.5">Unsuccessful payments</p>
        </div>
      </div>

      {/* Revenue trend */}
      <div className="card p-5">
        <h3 className="text-sm font-semibold text-gray-700 mb-1">Daily Revenue — Last 90 Days</h3>
        <p className="text-xs text-gray-400 mb-4">Paid transactions only (KES)</p>
        {chartData.length > 0 ? (
          <UserGrowthChart data={chartData} />
        ) : (
          <p className="text-gray-400 text-sm py-8 text-center">No revenue data yet</p>
        )}
      </div>

      {/* Status breakdown */}
      {totalTx > 0 && (
        <div className="card p-5 lg:w-1/2">
          <h3 className="text-sm font-semibold text-gray-700 mb-4">Transaction Status Breakdown</h3>
          <div className="space-y-2">
            {Object.entries(statusCounts)
              .sort(([, a], [, b]) => b - a)
              .map(([status, count]) => (
                <div key={status} className="flex items-center justify-between">
                  <span className={`badge ${STATUS_COLORS[status] ?? "bg-gray-100 text-gray-600"} capitalize`}>
                    {status.replace("_", " ")}
                  </span>
                  <span className="text-sm font-medium text-gray-700">
                    {count} ({totalTx > 0 ? Math.round((count / totalTx) * 100) : 0}%)
                  </span>
                </div>
              ))}
          </div>
        </div>
      )}
    </div>
  );
}
