import { createServiceClient } from "@/lib/supabase-server";
import { UserGrowthChart } from "@/components/charts/UserGrowthChart";
import { RequestsOffersChart } from "@/components/charts/RequestsOffersChart";

async function getTrendsData() {
  const db = createServiceClient();
  const since90 = new Date(Date.now() - 90 * 86400_000).toISOString();
  const since30 = new Date(Date.now() - 30 * 86400_000).toISOString();
  const since7  = new Date(Date.now() -  7 * 86400_000).toISOString();

  const [userRows, postRows, txRows] = await Promise.all([
    db.from("users").select("created_at").gte("created_at", since90).order("created_at"),
    db.from("posts").select("created_at, type").gte("created_at", since90).order("created_at"),
    db.from("transactions").select("created_at, total_paid, status").gte("created_at", since90).order("created_at"),
  ]);

  // User signups by day
  const userByDay: Record<string, number> = {};
  for (const u of userRows.data ?? []) {
    const day = u.created_at.slice(0, 10);
    userByDay[day] = (userByDay[day] ?? 0) + 1;
  }
  const userGrowth = Object.entries(userByDay)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, count]) => ({ date: date.slice(5), count }));

  // Posts by day
  const postByDay: Record<string, { date: string; requests: number; offers: number }> = {};
  for (const p of postRows.data ?? []) {
    const day = p.created_at.slice(0, 10);
    postByDay[day] ??= { date: day.slice(5), requests: 0, offers: 0 };
    if (p.type === "request") postByDay[day].requests++;
    if (p.type === "offer")   postByDay[day].offers++;
  }
  const postActivity = Object.values(postByDay).sort((a, b) => a.date.localeCompare(b.date));

  // Revenue by day
  const revenueByDay: Record<string, number> = {};
  for (const t of txRows.data ?? []) {
    if (!["paid", "payout_pending", "released"].includes(t.status)) continue;
    const day = t.created_at.slice(0, 10);
    revenueByDay[day] = (revenueByDay[day] ?? 0) + Math.round((t.total_paid ?? 0) / 100);
  }
  const revenueGrowth = Object.entries(revenueByDay)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, count]) => ({ date: date.slice(5), count }));

  // Summary stats
  const users7d = (userRows.data ?? []).filter((u) => u.created_at >= since7).length;
  const users30d = (userRows.data ?? []).filter((u) => u.created_at >= since30).length;
  const posts7d = (postRows.data ?? []).filter((p) => p.created_at >= since7).length;
  const posts30d = (postRows.data ?? []).filter((p) => p.created_at >= since30).length;

  return { userGrowth, postActivity, revenueGrowth, users7d, users30d, posts7d, posts30d };
}

export default async function TrendsPage() {
  const { userGrowth, postActivity, revenueGrowth, users7d, users30d, posts7d, posts30d } =
    await getTrendsData();

  return (
    <div className="space-y-6">
      {/* Quick stats */}
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <div className="card p-4">
          <p className="text-xs text-gray-500 font-medium uppercase tracking-wide mb-1">New Users (7d)</p>
          <p className="text-2xl font-bold text-gray-900">{users7d}</p>
        </div>
        <div className="card p-4">
          <p className="text-xs text-gray-500 font-medium uppercase tracking-wide mb-1">New Users (30d)</p>
          <p className="text-2xl font-bold text-gray-900">{users30d}</p>
        </div>
        <div className="card p-4">
          <p className="text-xs text-gray-500 font-medium uppercase tracking-wide mb-1">Posts (7d)</p>
          <p className="text-2xl font-bold text-indigo-600">{posts7d}</p>
        </div>
        <div className="card p-4">
          <p className="text-xs text-gray-500 font-medium uppercase tracking-wide mb-1">Posts (30d)</p>
          <p className="text-2xl font-bold text-indigo-600">{posts30d}</p>
        </div>
      </div>

      {/* Charts */}
      <div className="card p-5">
        <h3 className="text-sm font-semibold text-gray-700 mb-1">User Signups — Last 90 Days</h3>
        <p className="text-xs text-gray-400 mb-4">Daily new account registrations</p>
        {userGrowth.length > 0 ? (
          <UserGrowthChart data={userGrowth} />
        ) : (
          <p className="text-gray-400 text-sm py-8 text-center">No data yet</p>
        )}
      </div>

      <div className="card p-5">
        <h3 className="text-sm font-semibold text-gray-700 mb-1">Marketplace Activity — Last 90 Days</h3>
        <p className="text-xs text-gray-400 mb-4">Daily requests and offers posted</p>
        {postActivity.length > 0 ? (
          <RequestsOffersChart data={postActivity} />
        ) : (
          <p className="text-gray-400 text-sm py-8 text-center">No data yet</p>
        )}
      </div>

      <div className="card p-5">
        <h3 className="text-sm font-semibold text-gray-700 mb-1">Revenue — Last 90 Days (KES)</h3>
        <p className="text-xs text-gray-400 mb-4">Daily paid transaction volume</p>
        {revenueGrowth.length > 0 ? (
          <UserGrowthChart data={revenueGrowth} />
        ) : (
          <p className="text-gray-400 text-sm py-8 text-center">No revenue data yet</p>
        )}
      </div>
    </div>
  );
}
