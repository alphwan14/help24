import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";

type CompletedRow = {
  id: string;
  name: string | null;
  email: string | null;
  completed_jobs_count: number;
  average_rating: number | null;
  phone_number: string | null;
  created_at: string;
};

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getCompletedProviders() {
  const db = createServiceClient();
  const { data } = await db
    .from("users")
    .select("id, name, email, phone_number, completed_jobs_count, average_rating, created_at")
    .gt("completed_jobs_count", 0)
    .order("completed_jobs_count", { ascending: false })
    .limit(200);
  return (data ?? []) as CompletedRow[];
}

export default async function CompletedPage() {
  const rows = await getCompletedProviders();

  const totalCompleted = rows.reduce((s, r) => s + (r.completed_jobs_count ?? 0), 0);

  const columns = [
    {
      key: "name",
      label: "Provider",
      render: (r: CompletedRow) => (
        <div>
          <p className="font-medium text-gray-900">{r.name || "—"}</p>
          <p className="text-xs text-gray-400">{r.email}</p>
        </div>
      ),
    },
    {
      key: "phone_number",
      label: "Phone",
      render: (r: CompletedRow) => <span>{r.phone_number || "—"}</span>,
    },
    {
      key: "completed_jobs_count",
      label: "Jobs Done",
      render: (r: CompletedRow) => (
        <span className="badge bg-green-100 text-green-700 font-semibold">
          {r.completed_jobs_count}
        </span>
      ),
    },
    {
      key: "average_rating",
      label: "Avg Rating",
      render: (r: CompletedRow) =>
        r.average_rating ? (
          <span className="text-amber-600 font-medium">★ {Number(r.average_rating).toFixed(1)}</span>
        ) : (
          <span className="text-gray-400 text-xs">—</span>
        ),
    },
    {
      key: "created_at",
      label: "Joined",
      render: (r: CompletedRow) => <span className="text-gray-500">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-4">
      <p className="text-gray-500 text-sm">
        {rows.length} provider{rows.length !== 1 ? "s" : ""} · {totalCompleted.toLocaleString("en-KE")} total jobs completed
      </p>
      <DataTable columns={columns} rows={rows} emptyMessage="No completed jobs yet." />
    </div>
  );
}
