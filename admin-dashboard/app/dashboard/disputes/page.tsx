import { createServiceClient } from "@/lib/supabase-server";
import Link from "next/link";
import DataTable from "@/components/DataTable";

type DisputeRow = {
  id: string;
  status: string;
  reason: string;
  created_at: string;
  resolved_at: string | null;
  posts: { title: string | null } | null;
  transactions: { amount: number; total_paid: number } | null;
  raised_by: { name: string | null; phone_number: string | null } | null;
};

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-KE", {
    day: "2-digit",
    month: "short",
    year: "numeric",
  });
}

function fmtKES(n: number) {
  return `KES ${n.toLocaleString("en-KE")}`;
}

const STATUS_STYLES: Record<string, string> = {
  open: "bg-red-100 text-red-700",
  under_review: "bg-orange-100 text-orange-700",
  resolved_release: "bg-green-100 text-green-700",
  resolved_refund: "bg-blue-100 text-blue-700",
  resolved_partial: "bg-purple-100 text-purple-700",
};

async function getDisputes(): Promise<DisputeRow[]> {
  const db = createServiceClient();
  const { data } = await db
    .from("disputes")
    .select(
      `id, status, reason, created_at, resolved_at,
       posts(title),
       transactions(amount, total_paid),
       raised_by:raised_by_user_id(name, phone_number)`
    )
    .order("created_at", { ascending: false })
    .limit(200);
  return (data ?? []) as unknown as DisputeRow[];
}

export default async function DisputesPage() {
  const disputes = await getDisputes();

  const open = disputes.filter((d) => d.status === "open").length;
  const underReview = disputes.filter((d) => d.status === "under_review").length;
  const resolved = disputes.filter((d) =>
    ["resolved_release", "resolved_refund", "resolved_partial"].includes(d.status)
  ).length;

  const columns = [
    {
      key: "id",
      label: "Dispute",
      render: (r: DisputeRow) => (
        <div>
          <Link
            href={`/dashboard/disputes/${r.id}`}
            className="font-mono text-xs text-blue-600 hover:underline"
          >
            {r.id.slice(0, 12)}…
          </Link>
          <p className="text-xs text-gray-400 mt-0.5">{fmtDate(r.created_at)}</p>
        </div>
      ),
    },
    {
      key: "post",
      label: "Job",
      render: (r: DisputeRow) => (
        <span className="text-gray-700 text-sm truncate max-w-[160px] block">
          {r.posts?.title ?? "—"}
        </span>
      ),
    },
    {
      key: "reason",
      label: "Reason",
      render: (r: DisputeRow) => (
        <span className="text-gray-600 text-xs line-clamp-2 max-w-[220px]">
          {r.reason}
        </span>
      ),
    },
    {
      key: "amount",
      label: "At Stake",
      render: (r: DisputeRow) => (
        <span className="font-semibold text-amber-700 text-sm">
          {r.transactions ? fmtKES(r.transactions.amount) : "—"}
        </span>
      ),
    },
    {
      key: "status",
      label: "Status",
      render: (r: DisputeRow) => (
        <span
          className={`badge ${STATUS_STYLES[r.status] ?? "bg-gray-100 text-gray-600"}`}
        >
          {r.status.replace(/_/g, " ")}
        </span>
      ),
    },
    {
      key: "actions",
      label: "",
      render: (r: DisputeRow) =>
        !r.resolved_at ? (
          <Link
            href={`/dashboard/disputes/${r.id}`}
            className="text-xs font-semibold text-blue-600 hover:underline"
          >
            Review →
          </Link>
        ) : (
          <Link
            href={`/dashboard/disputes/${r.id}`}
            className="text-xs text-gray-400 hover:underline"
          >
            View →
          </Link>
        ),
    },
  ];

  return (
    <div className="space-y-6">
      {/* Summary cards */}
      <div className="grid grid-cols-3 gap-4">
        <div className="card p-4">
          <p className="text-xs text-gray-400 mb-1">Open</p>
          <p className="text-2xl font-bold text-red-600">{open}</p>
          <p className="text-xs text-gray-400 mt-1">Awaiting admin review</p>
        </div>
        <div className="card p-4">
          <p className="text-xs text-gray-400 mb-1">Under Review</p>
          <p className="text-2xl font-bold text-orange-600">{underReview}</p>
          <p className="text-xs text-gray-400 mt-1">Admin acknowledged</p>
        </div>
        <div className="card p-4">
          <p className="text-xs text-gray-400 mb-1">Resolved</p>
          <p className="text-2xl font-bold text-green-600">{resolved}</p>
          <p className="text-xs text-gray-400 mt-1">Closed disputes</p>
        </div>
      </div>

      {open > 0 && (
        <div className="flex items-center gap-2 p-3 bg-red-50 border border-red-200 rounded-xl text-sm text-red-700">
          <svg className="w-4 h-4 shrink-0" fill="currentColor" viewBox="0 0 20 20">
            <path
              fillRule="evenodd"
              d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.516 2.625H3.72c-1.347 0-2.189-1.458-1.515-2.625L8.485 2.495zM10 5a.75.75 0 01.75.75v3.5a.75.75 0 01-1.5 0v-3.5A.75.75 0 0110 5zm0 9a1 1 0 100-2 1 1 0 000 2z"
              clipRule="evenodd"
            />
          </svg>
          <span>
            <strong>{open} dispute{open > 1 ? "s" : ""}</strong> require your attention. Click{" "}
            <strong>Review</strong> to resolve.
          </span>
        </div>
      )}

      <DataTable
        columns={columns}
        rows={disputes}
        emptyMessage="No disputes found."
      />
    </div>
  );
}
