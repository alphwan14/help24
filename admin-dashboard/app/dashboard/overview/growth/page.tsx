import { createServiceClient } from "@/lib/supabase-server";
import { UserGrowthChart } from "@/components/charts/UserGrowthChart";
import { RequestsOffersChart } from "@/components/charts/RequestsOffersChart";

async function getGrowthData() {
  const db = createServiceClient();
  const since90 = new Date(Date.now() - 90 * 86400_000).toISOString();

  const [userRes, postRes] = await Promise.all([
    db.from("users").select("created_at").gte("created_at", since90).order("created_at"),
    db.from("posts").select("created_at, type").gte("created_at", since90).order("created_at"),
  ]);

  const userByDay: Record<string, number> = {};
  for (const u of userRes.data ?? []) {
    const day = u.created_at.slice(0, 10);
    userByDay[day] = (userByDay[day] ?? 0) + 1;
  }
  const userGrowth = Object.entries(userByDay)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, count]) => ({ date: date.slice(5), count }));

  const postByDay: Record<string, { date: string; requests: number; offers: number }> = {};
  for (const p of postRes.data ?? []) {
    const day = p.created_at.slice(0, 10);
    postByDay[day] ??= { date: day.slice(5), requests: 0, offers: 0 };
    if (p.type === "request") postByDay[day].requests++;
    if (p.type === "offer")   postByDay[day].offers++;
  }
  const postActivity = Object.values(postByDay).sort((a, b) => a.date.localeCompare(b.date));

  return { userGrowth, postActivity };
}

export default async function GrowthPage() {
  const { userGrowth, postActivity } = await getGrowthData();

  return (
    <div className="space-y-6">
      <div className="card p-5">
        <h3 className="text-sm font-semibold text-gray-700 mb-1">User Signups — Last 90 Days</h3>
        <p className="text-xs text-gray-400 mb-4">New accounts created per day</p>
        {userGrowth.length > 0 ? (
          <UserGrowthChart data={userGrowth} />
        ) : (
          <p className="text-gray-400 text-sm py-8 text-center">No signup data yet</p>
        )}
      </div>

      <div className="card p-5">
        <h3 className="text-sm font-semibold text-gray-700 mb-1">Marketplace Activity — Last 90 Days</h3>
        <p className="text-xs text-gray-400 mb-4">Requests and offers posted per day</p>
        {postActivity.length > 0 ? (
          <RequestsOffersChart data={postActivity} />
        ) : (
          <p className="text-gray-400 text-sm py-8 text-center">No post activity yet</p>
        )}
      </div>
    </div>
  );
}
