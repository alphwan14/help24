import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { PostStatusBadge, archivedRowClass } from "@/components/PostStatusBadge";
import { requestBudgetLabel } from "@/lib/post-display";

type JobRow = {
  id: string;
  title: string;
  category: string;
  location: string;
  price: number;
  pricing_type: string;
  status: string;
  archived_at: string | null;
  author_user_id: string | null;
  selected_provider_id: string | null;
  created_at: string;
  users: { name: string | null; email: string | null } | null;
};

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getActiveJobs() {
  const db = createServiceClient();
  const { data } = await db
    .from("posts")
    .select("id, title, category, location, price, pricing_type, status, archived_at, author_user_id, selected_provider_id, created_at, users(name, email)")
    .eq("type", "request")
    .not("selected_provider_id", "is", null)
    .order("created_at", { ascending: false })
    .limit(200);
  return (data ?? []) as unknown as JobRow[];
}

export default async function ActiveJobsPage() {
  const rows = await getActiveJobs();

  const columns = [
    {
      key: "title",
      label: "Request",
      render: (r: JobRow) => (
        <div className="max-w-xs">
          <p className="font-medium text-gray-900 truncate">{r.title}</p>
          <p className="text-xs text-gray-400">{r.category} · {r.location}</p>
        </div>
      ),
    },
    {
      key: "author",
      label: "Client",
      render: (r: JobRow) => (
        <span className="text-gray-600">
          {r.users?.name || r.users?.email || r.author_user_id?.slice(0, 12) || "—"}
        </span>
      ),
    },
    {
      key: "provider",
      label: "Provider ID",
      render: (r: JobRow) => (
        <span className="font-mono text-xs text-gray-500">
          {r.selected_provider_id?.slice(0, 14)}…
        </span>
      ),
    },
    {
      key: "price",
      label: "Value",
      render: (r: JobRow) => (
        <span className="font-medium">{requestBudgetLabel(r.price)}</span>
      ),
    },
    {
      key: "status",
      label: "Status",
      render: (r: JobRow) =>
        r.archived_at ? (
          <PostStatusBadge status={r.status} archivedAt={r.archived_at} />
        ) : (
          <span className="badge bg-amber-100 text-amber-700">In Progress</span>
        ),
    },
    {
      key: "created_at",
      label: "Posted",
      render: (r: JobRow) => <span className="text-gray-500">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-4">
      <p className="text-gray-500 text-sm">{rows.length} active job{rows.length !== 1 ? "s" : ""} (provider assigned)</p>
      <DataTable
        columns={columns}
        rows={rows}
        emptyMessage="No active jobs."
        rowClassName={(r) => archivedRowClass(r.archived_at)}
      />
    </div>
  );
}
