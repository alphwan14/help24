import { createServiceClient } from "@/lib/supabase-server";
import MetricCard from "@/components/MetricCard";
import { fmtKes } from "@/lib/post-display";
import { UserGrowthChart } from "@/components/charts/UserGrowthChart";
import { RequestsOffersChart } from "@/components/charts/RequestsOffersChart";
import { PaymentStatusBreakdown } from "@/components/charts/PaymentStatusBreakdown";
import { fillDays } from "@/lib/series";
import EarningsPanel from "@/components/charts/EarningsPanel";
import { DAYS_KEPT, buildSeries, type EarningEvent, type EarningsSeries } from "@/lib/earnings";

// Per request: nothing here reads the request, so without this Next would
// prerender the page once at build time (see loadOverview below).
export const dynamic = "force-dynamic";

const KENYA_CITIES = ["Nairobi", "Mombasa", "Kisumu", "Nakuru", "Eldoret", "Thika", "Nyeri", "Malindi"];

/** Statuses in which a customer's money has really been taken. */
const PAID_STATUSES = ["paid", "payout_pending", "released"];

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

/**
 * The twelve-query path, kept ONLY as a fallback.
 *
 * Migration 113 adds `admin_overview`, which returns all of this in one round
 * trip. This remains so that deploying the code and applying the migration can
 * happen in either order without an outage — if the function is not there yet,
 * the page still renders. Delete it once 113 is live everywhere.
 */
async function getDataViaTwelveQueries() {
  const db = createServiceClient();
  const since30 = new Date(Date.now() - 30 * 86400_000).toISOString();
  const since7  = new Date(Date.now() -  7 * 86400_000).toISOString();

  const results = await Promise.all([
    db.from("users").select("*", { count: "exact", head: true }),
    db.from("users").select("*", { count: "exact", head: true }).gte("last_login", since7),
    db.from("posts").select("*", { count: "exact", head: true }).eq("type", "request"),
    db.from("posts").select("*", { count: "exact", head: true }).eq("type", "offer"),
    // A job is active while a provider is on it and it has not finished —
    // a disputed job is still unresolved work. Counting every post that ever
    // had a provider (the old query) folded completed jobs in.
    db.from("posts").select("*", { count: "exact", head: true })
      .not("selected_provider_id", "is", null).in("status", ["assigned", "disputed"]),
    // Jobs, not providers: provider_reputation rows with completed_jobs > 0
    // counted the PEOPLE who had finished at least one.
    db.from("posts").select("*", { count: "exact", head: true }).eq("status", "completed"),
    db.from("transactions").select("*", { count: "exact", head: true }),
    db.from("escrow").select("amount").eq("status", "locked"),
    db.from("users").select("created_at").gte("created_at", since30).order("created_at"),
    db.from("posts").select("created_at, type").gte("created_at", since30).order("created_at"),
    db.from("transactions").select("created_at, total_paid, status").order("created_at", { ascending: false }).limit(200),
    db.from("posts").select("location").not("location", "is", null).limit(500),
    // Every paid transaction, not the latest 200 the status chart samples.
    db.from("transactions").select("total_paid, fee").in("status", PAID_STATUSES),
  ]);

  // THE SUPABASE CLIENT RETURNS ERRORS; IT DOES NOT THROW THEM.
  //
  // Every one of these was destructured straight to `{ count }` and then
  // coalesced with `?? 0`, so a query that failed produced a confident ZERO.
  // The page returned 200 and the dashboard reported, for example, no pending
  // escrow — which on a payments console is worse than an error, because an
  // error gets investigated and a zero gets believed.
  const failures = results.filter((r) => r.error);
  if (failures.length > 0) {
    throw new Error(
      `${failures.length} of ${results.length} overview queries failed: ` +
        failures.map((f) => f.error?.message ?? "unknown").join("; "),
    );
  }

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
    paidRows,
  ] = results;

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

  // What customers paid (provider earnings included) and, within it, what
  // Help24 earns. The first was labelled "Total Revenue"; revenue is the fees.
  const paid = (paidRows.data ?? []) as { total_paid: number | null; fee: number | null }[];
  const paymentsVolume = paid.reduce((s, t) => s + (t.total_paid ?? 0), 0);
  const platformFees = paid.reduce((s, t) => s + (t.fee ?? 0), 0);

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
      paymentsVolume,
      platformFees,
    },
    userGrowth,
    postActivity,
    paymentStatus,
    geoPoints,
    totalLocs,
  };
}

function fmtNum(n: number) { return n.toLocaleString("en-KE"); }
// Whole KES, like every other money figure here (see lib/money-units.test.mjs).
const fmtKES = fmtKes;

function SectionLabel({ children }: { children: React.ReactNode }) {
  return <h2 className="text-[12px] font-semibold text-gray-500 mb-2.5">{children}</h2>;
}

function ChartHeader({ title, sub }: { title: string; sub?: string }) {
  return (
    <div className="mb-4">
      <h3 className="text-[14px] font-semibold text-gray-900 leading-tight">{title}</h3>
      {sub && <p className="text-[12px] text-gray-500 mt-0.5">{sub}</p>}
    </div>
  );
}

/* ═══════════════════════════════════════════════════════════
   PAGE
═══════════════════════════════════════════════════════════ */
type Overview = Awaited<ReturnType<typeof getDataViaTwelveQueries>>;

/**
 * The overview data, in ONE round trip, read fresh on every visit.
 *
 * ── Why one call ────────────────────────────────────────────────────────────
 * This page used to issue twelve PostgREST requests per load. Measured from
 * Nairobi against this project, a request that never reaches Postgres costs
 * 161–602 ms and a real query costs 343–512 ms — the same number. The database
 * is not the cost; the ROUND TRIP is, and the page was buying twelve of them.
 *
 * ── Why it is not cached ────────────────────────────────────────────────────
 * It was (Next's data cache, 60-second revalidate) when a load cost twelve round
 * trips. That cache answers the first request after it expires with the OLD
 * result and refreshes in the background, so on a console opened a few times a
 * day the first view was routinely stale. Now that admin_overview is one round
 * trip, the cache buys little and costs the truth (lib/route-freshness.test.mjs).
 *
 * ── Why there is still a fallback ───────────────────────────────────────────
 * `admin_overview` arrives in migration 113. Until that is applied everywhere,
 * a missing function must not blank the dashboard, so the old path stays until
 * the migration is live.
 */
async function loadOverview(): Promise<Overview> {
    const db = createServiceClient();
    const { data, error } = await db.rpc("admin_overview", { p_cities: KENYA_CITIES });

    // Before migration 131 the function counted every post that ever had a
    // provider as active, providers as completed jobs, and called the gross
    // paid amount revenue. A result without paymentsVolume is that version:
    // its numbers are wrong, so the corrected queries answer instead.
    if (!error && data && (data as Overview).kpis?.paymentsVolume != null) return data as Overview;

    console.warn(
      "[overview] admin_overview unavailable or pre-131, falling back to 12 queries:",
      error?.message ?? "no paymentsVolume",
    );
    return getDataViaTwelveQueries();
}

/** Every row of a query, page by page (PostgREST returns at most 1,000 at a time). */
async function allRows<T>(page: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; from < 50_000; from += 1000) {
    const { data, error } = await page(from, from + 999);
    if (error) throw new Error(error.message);
    out.push(...(data ?? []));
    if (!data || data.length < 1000) break;
  }
  return out;
}

/**
 * The last DAYS_KEPT days of earnings: fees on paid jobs, and promotion sales.
 * Null when either read fails: the panel then says it could not read them,
 * rather than drawing a confident zero (see the note in getDataViaTwelveQueries).
 */
async function loadEarnings(): Promise<EarningsSeries | null> {
  try {
    const db = createServiceClient();
    // A day's margin either side of the Nairobi window; buildSeries trims it.
    const since = new Date(Date.now() - (DAYS_KEPT + 1) * 86400_000).toISOString();
    const [fees, promos] = await Promise.all([
      allRows<{ created_at: string; fee: number | null }>((from, to) =>
        db
          .from("transactions")
          .select("created_at, fee")
          .in("status", PAID_STATUSES)
          .gte("created_at", since)
          .order("created_at")
          .range(from, to),
      ),
      allRows<{ paid_at: string | null; created_at: string; amount_kes: number | null }>((from, to) =>
        db
          .from("promotion_payments")
          .select("paid_at, created_at, amount_kes")
          .eq("status", "paid")
          .gte("created_at", since)
          .order("created_at")
          .range(from, to),
      ),
    ]);
    const events: EarningEvent[] = [
      ...fees.map((t) => ({ at: t.created_at, amount: t.fee ?? 0, stream: "fees" as const })),
      ...promos.map((p) => ({ at: p.paid_at ?? p.created_at, amount: p.amount_kes ?? 0, stream: "promos" as const })),
    ];
    return buildSeries(events);
  } catch (e) {
    console.warn("[overview] earnings unavailable:", e instanceof Error ? e.message : e);
    return null;
  }
}

export default async function OverviewGeneralPage() {
  let overview: Overview | null = null;
  let failure: string | null = null;
  const earningsPromise = loadEarnings();

  try {
    overview = await loadOverview();
  } catch (e) {
    // A page that returns 200 with its numbers quietly missing is worse than
    // one that says it could not read them. This is a payments console.
    failure = e instanceof Error ? e.message : String(e);
  }

  if (!overview) {
    return (
      <div className="space-y-6">
        <div className="card p-6 border-critical-300 bg-critical-50">
          <p className="text-sm font-semibold text-critical-700">
            Could not load platform figures
          </p>
          <p className="text-xs text-critical-600 mt-1.5 leading-relaxed">
            The database did not answer. Nothing is shown below rather than
            numbers that may be wrong. Reload to try again.
          </p>
          {failure && (
            <p className="text-[11px] font-mono text-critical-600/80 mt-3 break-all">
              {failure}
            </p>
          )}
        </div>
      </div>
    );
  }

  const { kpis, paymentStatus, geoPoints, totalLocs } = overview;
  const userGrowth = fillDays(overview.userGrowth, { count: 0 });
  const postActivity = fillDays(overview.postActivity, { requests: 0, offers: 0 });
  const signups30 = userGrowth.reduce((s, d) => s + d.count, 0);
  const posts30 = postActivity.reduce((s, d) => s + d.requests + d.offers, 0);
  const txSample = paymentStatus.reduce((s, d) => s + d.value, 0);
  const earnings = await earningsPromise;

  return (
    <div className="space-y-6 lg:space-y-8">
      {/* Ranked by the question each answers: who is on Help24, is it
          growing, what it earns, the money behind that, then diagnostics. */}
      <section>
        <SectionLabel>Platform</SectionLabel>
        <div className="grid grid-cols-2 gap-2.5 sm:gap-4 lg:grid-cols-4">
          <MetricCard label="Users" value={fmtNum(kpis.totalUsers)} icon="users" />
          <MetricCard label="Active this week" value={fmtNum(kpis.activeUsers7d)} icon="active" sub="Signed in, 7 days" />
          <MetricCard label="Requests" value={fmtNum(kpis.totalRequests)} icon="requests" />
          <MetricCard label="Offers" value={fmtNum(kpis.totalOffers)} icon="offers" />
        </div>
      </section>

      <section className="grid grid-cols-1 gap-4 lg:gap-6 lg:grid-cols-2">
        <div className="chart-card">
          <ChartHeader title="Signups" sub={`${fmtNum(signups30)} in the last 30 days`} />
          <div className="h-[180px] sm:h-[220px] lg:h-[240px]">
            <UserGrowthChart data={userGrowth} bars />
          </div>
        </div>
        <div className="chart-card">
          <ChartHeader title="Requests and offers" sub={`${fmtNum(posts30)} posted in the last 30 days`} />
          <div className="h-[180px] sm:h-[220px] lg:h-[240px]">
            <RequestsOffersChart data={postActivity} />
          </div>
        </div>
      </section>

      <EarningsPanel series={earnings} />

      <section>
        <SectionLabel>Jobs and money</SectionLabel>
        <div className="grid grid-cols-2 gap-2.5 sm:gap-4 lg:grid-cols-5">
          <MetricCard label="Active jobs" value={fmtNum(kpis.activeJobs)} icon="jobs" sub="Provider on it" />
          <MetricCard label="Completed jobs" value={fmtNum(kpis.completedJobs)} icon="jobs" />
          <MetricCard label="Transactions" value={fmtNum(kpis.totalTx)} icon="transactions" />
          <MetricCard label="Held in escrow" value={fmtKES(kpis.pendingEscrow)} icon="escrow" sub="Locked funds" />
          <MetricCard
            className="col-span-2 lg:col-span-1"
            label="Payments volume"
            value={fmtKES(kpis.paymentsVolume)}
            icon="revenue"
            sub={kpis.platformFees == null ? "Paid by customers" : `Fees ${fmtKES(kpis.platformFees)}`}
          />
        </div>
      </section>

      <section className="grid grid-cols-1 gap-4 lg:gap-6 lg:grid-cols-2">
        {paymentStatus.length > 0 && (
          <div className="chart-card">
            <ChartHeader title="Payment status" sub={`Latest ${fmtNum(txSample)} transactions`} />
            <PaymentStatusBreakdown data={paymentStatus} />
          </div>
        )}
        {geoPoints.length > 0 && (
          <div className="chart-card">
            <ChartHeader title="Top cities" sub={`By post location, ${totalLocs.toLocaleString("en-KE")} posts`} />
            <ul className="divide-y divide-gray-100">
              {geoPoints.map((g) => (
                <li key={g.city} className="flex items-center gap-3 py-2.5">
                  <span className="text-[13px] text-gray-700 w-20 shrink-0 truncate">{g.city}</span>
                  <div className="flex-1 bg-gray-100 rounded-full h-1.5 overflow-hidden min-w-0">
                    <div className="bg-brand-500 h-1.5 rounded-full" style={{ width: `${g.pct}%` }} />
                  </div>
                  <span className="text-[13px] font-semibold text-gray-900 tabular-nums w-10 text-right">
                    {g.count.toLocaleString("en-KE")}
                  </span>
                  <span className="text-[12px] text-gray-400 tabular-nums w-9 text-right">{g.pct}%</span>
                </li>
              ))}
            </ul>
          </div>
        )}
      </section>
    </div>
  );
}
