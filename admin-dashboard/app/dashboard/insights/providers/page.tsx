import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";

type ProviderRow = {
  id: string;
  name: string | null;
  email: string | null;
  phone_number: string | null;
  completed_jobs_count: number;
  average_rating: number | null;
  created_at: string;
  last_login: string | null;
};

function fmtDate(iso: string | null) {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getTopProviders() {
  const db = createServiceClient();
  const { data } = await db
    .from("users")
    .select("id, name, email, phone_number, completed_jobs_count, average_rating, created_at, last_login")
    .gt("completed_jobs_count", 0)
    .order("completed_jobs_count", { ascending: false })
    .limit(50);
  return (data ?? []) as ProviderRow[];
}

export default async function TopProvidersPage() {
  const rows = await getTopProviders();

  const totalJobs = rows.reduce((s, r) => s + (r.completed_jobs_count ?? 0), 0);
  const avgRating =
    rows.filter((r) => r.average_rating).reduce((s, r) => s + (r.average_rating ?? 0), 0) /
    (rows.filter((r) => r.average_rating).length || 1);

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
      key: "completed_jobs_count",
      label: "Jobs Done",
      render: (r: ProviderRow) => (
        <span className="font-bold text-gray-900">{r.completed_jobs_count.toLocaleString("en-KE")}</span>
      ),
    },
    {
      key: "average_rating",
      label: "Avg Rating",
      render: (r: ProviderRow) =>
        r.average_rating ? (
          <span className={`font-semibold ${r.average_rating >= 4.5 ? "text-green-600" : r.average_rating >= 3.5 ? "text-amber-600" : "text-red-500"}`}>
            ★ {Number(r.average_rating).toFixed(1)}
          </span>
        ) : (
          <span className="text-gray-400 text-xs">—</span>
        ),
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
            {rows.some((r) => r.average_rating) ? `★ ${avgRating.toFixed(1)}` : "—"}
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
