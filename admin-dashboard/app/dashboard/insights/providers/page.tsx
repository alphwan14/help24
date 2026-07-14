import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { ratingLabel, type ProviderRep } from "@/lib/reputation";

// Rankings come from provider_reputation — the server-derived source the
// mobile app displays. The dead users.* stat columns are not read.

type ProviderRow = ProviderRep & {
  name: string | null;
  email: string | null;
  phone_number: string | null;
  created_at: string | null;
  last_login: string | null;
};

function fmtDate(iso: string | null) {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getTopProviders(): Promise<ProviderRow[]> {
  const db = createServiceClient();
  const { data: reps, error } = await db
    .from("provider_reputation")
    .select(
      "provider_id, completed_jobs, avg_rating, total_reviews, completion_rate, dispute_rate, open_disputes, tier",
    )
    .gt("completed_jobs", 0)
    .order("completed_jobs", { ascending: false })
    .limit(50);
  if (error) console.error("[insights/providers] ERROR:", error.message);
  const repRows = (reps ?? []) as ProviderRep[];
  if (repRows.length === 0) return [];

  const { data: users } = await db
    .from("users")
    .select("id, name, email, phone_number, created_at, last_login")
    .in("id", repRows.map((r) => r.provider_id));
  const byId = new Map((users ?? []).map((u) => [u.id, u]));

  return repRows.map((r) => {
    const u = byId.get(r.provider_id);
    return {
      ...r,
      name: u?.name ?? null,
      email: u?.email ?? null,
      phone_number: u?.phone_number ?? null,
      created_at: u?.created_at ?? null,
      last_login: u?.last_login ?? null,
    };
  });
}

export default async function TopProvidersPage() {
  const rows = await getTopProviders();

  const totalJobs = rows.reduce((s, r) => s + (r.completed_jobs ?? 0), 0);
  const rated = rows.filter((r) => r.total_reviews > 0 && r.avg_rating != null);
  const avgRating = rated.reduce((s, r) => s + (r.avg_rating ?? 0), 0) / (rated.length || 1);

  const columns = [
    {
      key: "rank",
      label: "#",
      render: (_: ProviderRow, i: number) => (
        <span className={`font-bold text-sm ${i < 3 ? "text-amber-500" : "text-gray-400"}`}>
          {i + 1}
        </span>
      ),
    },
    {
      key: "name",
      label: "Provider",
      render: (r: ProviderRow) => (
        <div>
          <p className="font-medium text-gray-900">{r.name || "—"}</p>
          <p className="text-xs text-gray-400">{r.email}</p>
        </div>
      ),
    },
    {
      key: "phone_number",
      label: "M-Pesa",
      render: (r: ProviderRow) =>
        r.phone_number ? (
          <span className="badge bg-green-100 text-green-700">{r.phone_number}</span>
        ) : (
          <span className="badge bg-red-100 text-red-600">Not set</span>
        ),
    },
    {
      key: "completed_jobs",
      label: "Jobs Done",
      render: (r: ProviderRow) => (
        <span className="font-bold text-gray-900">{r.completed_jobs.toLocaleString("en-KE")}</span>
      ),
    },
    {
      key: "avg_rating",
      label: "Avg Rating",
      render: (r: ProviderRow) => {
        const label = ratingLabel(r);
        if (!label) return <span className="text-gray-400 text-xs">—</span>;
        const v = r.avg_rating ?? 0;
        return (
          <span className={`font-semibold ${v >= 4.5 ? "text-green-600" : v >= 3.5 ? "text-amber-600" : "text-red-500"}`}>
            {label}
          </span>
        );
      },
    },
    {
      key: "dispute_rate",
      label: "Dispute Rate",
      render: (r: ProviderRow) => {
        const pct = Math.round((r.dispute_rate ?? 0) * 100);
        return (
          <span className={pct > 20 ? "text-red-600 font-semibold" : "text-gray-600"}>{pct}%</span>
        );
      },
    },
    {
      key: "last_login",
      label: "Last Active",
      render: (r: ProviderRow) => <span className="text-gray-500">{fmtDate(r.last_login)}</span>,
    },
    {
      key: "created_at",
      label: "Joined",
      render: (r: ProviderRow) => <span className="text-gray-500">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-6">
      {/* Stats */}
      <div className="grid grid-cols-3 gap-4">
        <div className="card p-4 text-center">
          <p className="text-2xl font-bold text-gray-900">{rows.length}</p>
          <p className="text-xs text-gray-500 mt-1">Active providers</p>
        </div>
        <div className="card p-4 text-center">
          <p className="text-2xl font-bold text-indigo-600">{totalJobs.toLocaleString("en-KE")}</p>
          <p className="text-xs text-gray-500 mt-1">Total jobs completed</p>
        </div>
        <div className="card p-4 text-center">
          <p className="text-2xl font-bold text-amber-600">
            {rated.length > 0 ? `★ ${avgRating.toFixed(1)}` : "—"}
          </p>
          <p className="text-xs text-gray-500 mt-1">Platform avg rating</p>
        </div>
      </div>

      {/* Table */}
      <div className="card p-5">
        <h3 className="text-sm font-semibold text-gray-700 mb-4">Top 50 Providers by Jobs Completed</h3>
        <DataTable columns={columns} rows={rows} emptyMessage="No providers with completed jobs yet." />
      </div>
    </div>
  );
}
