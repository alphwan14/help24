import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { PostStatusBadge, archivedRowClass } from "@/components/PostStatusBadge";

type RequestRow = {
  id: string;
  title: string;
  category: string;
  location: string;
  price: number;
  pricing_type: string;
  urgency: string;
  status: string;
  archived_at: string | null;
  author_user_id: string | null;
  selected_provider_id: string | null;
  created_at: string;
  users: { name: string | null; email: string | null } | null;
};

const STATUS_FILTERS = ["all", "open", "assigned"] as const;
type StatusFilter = (typeof STATUS_FILTERS)[number];

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getRequests(status: StatusFilter) {
  const db = createServiceClient();
  let query = db
    .from("posts")
    .select("id, title, category, location, price, pricing_type, urgency, status, archived_at, author_user_id, selected_provider_id, created_at, users(name, email)")
    .eq("type", "request")
    .order("created_at", { ascending: false })
    .limit(200);

  if (status === "open") query = query.is("selected_provider_id", null);
  if (status === "assigned") query = query.not("selected_provider_id", "is", null);

  const { data } = await query;
  return (data ?? []) as unknown as RequestRow[];
}

export default async function MarketplaceRequestsPage({
  searchParams,
}: {
  searchParams: Promise<{ status?: string }>;
}) {
  const params = await searchParams;
  const status: StatusFilter = STATUS_FILTERS.includes(params.status as StatusFilter)
    ? (params.status as StatusFilter)
    : "all";

  const rows = await getRequests(status);

  const columns = [
    {
      key: "title",
      label: "Title",
      render: (r: RequestRow) => (
        <div className="max-w-xs">
          <p className="font-medium text-gray-900 truncate">{r.title}</p>
          <p className="text-xs text-gray-400">{r.category} · {r.location}</p>
        </div>
      ),
    },
    {
      key: "author",
      label: "Posted By",
      render: (r: RequestRow) => (
        <span className="text-gray-600">
          {r.users?.name || r.users?.email || r.author_user_id?.slice(0, 12) || "—"}
        </span>
      ),
    },
    {
      key: "price",
      label: "Budget",
      render: (r: RequestRow) => (
        <span className="font-medium">KES {r.price.toLocaleString("en-KE")} / {r.pricing_type}</span>
      ),
    },
    {
      key: "urgency",
      label: "Urgency",
      render: (r: RequestRow) => {
        const colors: Record<string, string> = {
          urgent: "bg-red-100 text-red-700",
          soon: "bg-amber-100 text-amber-700",
          flexible: "bg-gray-100 text-gray-600",
        };
        return (
          <span className={`badge ${colors[r.urgency] ?? "bg-gray-100 text-gray-600"}`}>{r.urgency}</span>
        );
      },
    },
    {
      key: "status",
      label: "Status",
      render: (r: RequestRow) => (
        <PostStatusBadge status={r.status} archivedAt={r.archived_at} />
      ),
    },
    {
      key: "created_at",
      label: "Posted",
      render: (r: RequestRow) => <span className="text-gray-500">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <p className="text-gray-500 text-sm">{rows.length} results</p>
        <div className="flex gap-1 bg-gray-100 rounded-lg p-1">
          {STATUS_FILTERS.map((f) => (
            <a
              key={f}
              href={`?status=${f}`}
              className={`px-4 py-1.5 rounded-md text-sm font-medium transition-colors capitalize ${
                status === f ? "bg-white shadow-sm text-gray-900" : "text-gray-500 hover:text-gray-700"
              }`}
            >
              {f}
            </a>
          ))}
        </div>
      </div>
      <DataTable
        columns={columns}
        rows={rows}
        emptyMessage="No requests found."
        rowClassName={(r) => archivedRowClass(r.archived_at)}
      />
    </div>
  );
}
