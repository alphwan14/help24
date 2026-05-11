import { createServiceClient } from "@/lib/supabase-server";
import MetricCard from "@/components/MetricCard";
import { UserGrowthChart } from "@/components/charts/UserGrowthChart";
import { RequestsOffersChart } from "@/components/charts/RequestsOffersChart";
import { PaymentStatusChart } from "@/components/charts/PaymentStatusChart";

const KENYA_CITIES = ["Nairobi", "Mombasa", "Kisumu", "Nakuru", "Eldoret", "Thika", "Nyeri", "Malindi"];

function extractCity(location: string | null): string {
  if (!location) return "Other";
  const loc = location.toLowerCase();
  for (const city of KENYA_CITIES) {
    if (loc.includes(city.toLowerCase())) return city;
  }
  return "Other";
}

function groupByDay<T extends { created_at: string }>(rows: T[]): Record<string, T[]> {
  const out: Record<string, T[]> = {};
  for (const r of rows) {
    const day = r.created_at.slice(0, 10);
    (out[day] ??= []).push(r);
  }
  return out;
}

async function getData() {
  const db = createServiceClient();
  const since30 = new Date(Date.now() - 30 * 86400_000).toISOString();
  const since7  = new Date(Date.now() -  7 * 86400_000).toISOString();

  const [
    { count: totalUsers },
    { count: activeUsers7d },
    { count: totalRequests },
    { count: totalOffers },
    { count: activeJobs },
    { count: completedJobs },
    { count: totalTx },
    escrowRes,
    userRows,
    postRows,
    txRows,
    locRows,
  ] = await Promise.all([
    db.from("users").select("*", { count: "exact", head: true }),
    db.from("users").select("*", { count: "exact", head: true }).gte("last_login", since7),
    db.from("posts").select("*", { count: "exact", head: true }).eq("type", "request"),
    db.from("posts").select("*", { count: "exact", head: true }).eq("type", "offer"),
    db.from("posts").select("*", { count: "exact", head: true }).not("selected_provider_id", "is", null),
    db.from("users").select("*", { count: "exact", head: true }).gt("completed_jobs_count", 0),
    db.from("transactions").select("*", { count: "exact", head: true }),
    db.from("escrow").select("amount").eq("status", "locked"),
    db.from("users").select("created_at").gte("created_at", since30).order("created_at"),
    db.from("posts").select("created_at, type").gte("created_at", since30).order("created_at"),
    db.from("transactions").select("created_at, total_paid, status").order("created_at", { ascending: false }).limit(200),
    db.from("posts").select("location").not("location", "is", null).limit(500),
  ]);

  const pendingEscrow = (escrowRes.data ?? []).reduce(
    (s: number, r: { amount: number }) => s + (r.amount ?? 0), 0
  );

  const userByDay = groupByDay(userRows.data ?? []);
  const userGrowth = Object.entries(userByDay)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([date, rows]) => ({ date: date.slice(5), count: rows.length }));

  const postByDay: Record<string, { date: string; requests: number; offers: number }> = {};
  for (const p of postRows.data ?? []) {
    const day = p.created_at.slice(0, 10);
    postByDay[day] ??= { date: day.slice(5), requests: 0, offers: 0 };
    if (p.type === "request") postByDay[day].requests++;
    if (p.type === "offer")   postByDay[day].offers++;
  }
  const postActivity = Object.values(postByDay).sort((a, b) => a.date.localeCompare(b.date));

  const statusCounts: Record<string, number> = {};
  for (const t of txRows.data ?? []) {
    statusCounts[t.status] = (statusCounts[t.status] ?? 0) + 1;
  }
  const paymentStatus = Object.entries(statusCounts).map(([name, value]) => ({ name, value }));

  const totalRevenue = (txRows.data ?? [])
    .filter((t) => ["paid", "payout_pending", "released"].includes(t.status))
    .reduce((s, t) => s + (t.total_paid ?? 0), 0);

  const cityCounts: Record<string, number> = {};
  for (const p of locRows.data ?? []) {
    const city = extractCity(p.location);
    cityCounts[city] = (cityCounts[city] ?? 0) + 1;
  }
  const totalLocs = Object.values(cityCounts).reduce((s, n) => s + n, 0);
  const geoPoints = Object.entries(cityCounts)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 6)
    .map(([city, count]) => ({
      city,
      count,
      pct: totalLocs > 0 ? Math.round((count / totalLocs) * 100) : 0,
    }));

  return {
    kpis: {
      totalUsers:    totalUsers    ?? 0,
      activeUsers7d: activeUsers7d ?? 0,
      totalRequests: totalRequests ?? 0,
      totalOffers:   totalOffers   ?? 0,
      activeJobs:    activeJobs    ?? 0,
      completedJobs: completedJobs ?? 0,
      totalTx:       totalTx       ?? 0,
      pendingEscrow,
      totalRevenue,
    },
    userGrowth,
    postActivity,
    paymentStatus,
    geoPoints,
    totalLocs,
  };
}

function fmtNum(n: number) { return n.toLocaleString("en-KE"); }
function fmtKES(n: number) {
  return `KES ${(n / 100).toLocaleString("en-KE", { minimumFractionDigits: 0, maximumFractionDigits: 0 })}`;
}

/* ─── Section label ─────────────────────────────────────── */
function SectionLabel({ children }: { children: React.ReactNode }) {
  return (
    <p className="text-[10.5px] font-semibold text-gray-400 uppercase tracking-widest mb-3">
      {children}
    </p>
  );
}

/* ─── Chart card header ─────────────────────────────────── */
function ChartHeader({ title, sub }: { title: string; sub?: string }) {
  return (
    <div className="mb-5">
      <p className="text-[13.5px] font-semibold text-gray-800 leading-none">{title}</p>
      {sub && <p className="text-[11.5px] text-gray-400 mt-1">{sub}</p>}
    </div>
  );
}

/* ═══════════════════════════════════════════════════════════
   PAGE
═══════════════════════════════════════════════════════════ */
export default async function OverviewGeneralPage() {
  const { kpis, userGrowth, postActivity, paymentStatus, geoPoints, totalLocs } = await getData();

  return (
    <div className="space-y-8">

      {/* ── Platform KPIs ── */}
      <section>
        <SectionLabel>Platform</SectionLabel>
        <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
          <MetricCard
            label="Total Users"
            value={fmtNum(kpis.totalUsers)}
            accent="blue"
            icon="users"
          />
          <MetricCard
            label="Active (7-day)"
            value={fmtNum(kpis.activeUsers7d)}
            accent="green"
            icon="active"
            sub="Logged in recently"
          />
          <MetricCard
            label="Requests"
            value={fmtNum(kpis.totalRequests)}
            icon="requests"
          />
          <MetricCard
            label="Offers"
            value={fmtNum(kpis.totalOffers)}
            accent="purple"
            icon="offers"
          />
        </div>
      </section>

      {/* ── Operations KPIs ── */}
      <section>
        <SectionLabel>Operations &amp; Finance</SectionLabel>
        <div className="grid grid-cols-2 gap-4 lg:grid-cols-5">
          <MetricCard
            label="Active Jobs"
            value={fmtNum(kpis.activeJobs)}
            accent="yellow"
            icon="jobs"
            sub="Provider assigned"
          />
          <MetricCard
            label="Completed Jobs"
            value={fmtNum(kpis.completedJobs)}
            accent="green"
            icon="jobs"
          />
          <MetricCard
            label="Transactions"
            value={fmtNum(kpis.totalTx)}
            icon="transactions"
          />
          <MetricCard
            label="Pending Escrow"
            value={fmtKES(kpis.pendingEscrow)}
            accent="yellow"
            icon="escrow"
            sub="Locked funds"
          />
          <MetricCard
            label="Total Revenue"
            value={fmtKES(kpis.totalRevenue)}
            accent="green"
            icon="revenue"
          />
        </div>
      </section>

      {/* ── User growth chart (full width) ── */}
      {userGrowth.length > 0 && (
        <section className="chart-card">
          <ChartHeader
            title="User Signups — Last 30 Days"
            sub="New account registrations per day"
          />
          <UserGrowthChart data={userGrowth} />
        </section>
      )}

      {/* ── Marketplace activity + Payment status ── */}
      <section className="grid grid-cols-1 gap-6 lg:grid-cols-5">
        {postActivity.length > 0 && (
          <div className="chart-card lg:col-span-3">
            <ChartHeader
              title="Requests vs Offers — Last 30 Days"
              sub="Daily marketplace posting activity"
            />
            <RequestsOffersChart data={postActivity} />
          </div>
        )}
        {paymentStatus.length > 0 && (
          <div className="chart-card lg:col-span-2">
            <ChartHeader
              title="Payment Status"
              sub="Distribution across last 200 transactions"
            />
            <PaymentStatusChart data={paymentStatus} />
          </div>
        )}
      </section>

      {/* ── Kenya geography ── */}
      {geoPoints.length > 0 && (
        <section className="chart-card">
          <ChartHeader
            title="Regional Activity — Kenya"
            sub={`Top cities by post volume · ${totalLocs.toLocaleString("en-KE")} data points`}
          />
          <div className="space-y-4">
            {geoPoints.map((g) => (
              <div key={g.city} className="flex items-center gap-4">
                <span className="text-[12.5px] font-medium text-gray-600 w-20 shrink-0 tabular-nums">
                  {g.city}
                </span>
                <div className="flex-1 bg-gray-100 rounded-full h-1.5 overflow-hidden">
                  <div
                    className="bg-brand-500 h-1.5 rounded-full transition-all"
                    style={{ width: `${g.pct}%` }}
                  />
                </div>
                <div className="flex items-center gap-2 w-28 justify-end shrink-0">
                  <span className="text-[12px] font-semibold text-gray-700 tabular-nums">
                    {g.count.toLocaleString("en-KE")}
                  </span>
                  <span className="text-[11px] text-gray-400 tabular-nums w-8 text-right">
                    {g.pct}%
                  </span>
                </div>
              </div>
            ))}
          </div>
        </section>
      )}

    </div>
  );
}
