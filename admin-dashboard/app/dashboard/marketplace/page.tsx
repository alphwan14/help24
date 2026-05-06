import { createServiceClient } from "@/lib/supabase-server";
import { RequestsOffersChart } from "@/components/charts/RequestsOffersChart";
import MetricCard from "@/components/MetricCard";

async function getMarketplaceData() {
  const db = createServiceClient();
  const since30 = new Date(Date.now() - 30 * 86400_000).toISOString();

  const [
    { count: totalRequests },
    { count: totalOffers },
    { count: activeJobs },
    { count: completedJobs },
    { count: openRequests },
    postRows,
  ] = await Promise.all([
    db.from("posts").select("*", { count: "exact", head: true }).eq("type", "request"),
    db.from("posts").select("*", { count: "exact", head: true }).eq("type", "offer"),
    db.from("posts").select("*", { count: "exact", head: true }).not("selected_provider_id", "is", null),
    db.from("users").select("*", { count: "exact", head: true }).gt("completed_jobs_count", 0),
    db.from("posts").select("*", { count: "exact", head: true }).eq("type", "request").is("selected_provider_id", null),
    db.from("posts").select("created_at, type").gte("created_at", since30).order("created_at"),
  ]);

  const postByDay: Record<string, { date: string; requests: number; offers: number }> = {};
  for (const p of postRows.data ?? []) {
    const day = p.created_at.slice(0, 10);
    postByDay[day] ??= { date: day.slice(5), requests: 0, offers: 0 };
    if (p.type === "request") postByDay[day].requests++;
    if (p.type === "offer")   postByDay[day].offers++;
  }
  const postActivity = Object.values(postByDay).sort((a, b) => a.date.localeCompare(b.date));

  return {
    kpis: {
      totalRequests: totalRequests ?? 0,
      totalOffers: totalOffers ?? 0,
      activeJobs: activeJobs ?? 0,
      completedJobs: completedJobs ?? 0,
      openRequests: openRequests ?? 0,
    },
    postActivity,
  };
}

function fmt(n: number) { return n.toLocaleString("en-KE"); }

export default async function MarketplaceAllPage() {
  const { kpis, postActivity } = await getMarketplaceData();

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-5">
        <MetricCard label="Total Requests"  value={fmt(kpis.totalRequests)} />
        <MetricCard label="Open Requests"   value={fmt(kpis.openRequests)}  accent="blue" sub="No provider yet" />
        <MetricCard label="Total Offers"    value={fmt(kpis.totalOffers)}   accent="purple" />
        <MetricCard label="Active Jobs"     value={fmt(kpis.activeJobs)}    accent="yellow" sub="Provider assigned" />
        <MetricCard label="Completed Jobs"  value={fmt(kpis.completedJobs)} accent="green" />
      </div>

      <div className="card p-5">
        <h3 className="text-sm font-semibold text-gray-700 mb-1">Activity — Last 30 Days</h3>
        <p className="text-xs text-gray-400 mb-4">Requests and offers posted per day</p>
        {postActivity.length > 0 ? (
          <RequestsOffersChart data={postActivity} />
        ) : (
          <p className="text-gray-400 text-sm py-8 text-center">No activity yet</p>
        )}
      </div>
    </div>
  );
}
