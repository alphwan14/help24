import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { ArchivedBadge } from "@/components/PostStatusBadge";

type TxRow = {
  id: string;
  post_id: string;
  buyer_user_id: string | null;
  amount: number;
  total_paid: number;
  status: string;
  mpesa_receipt: string | null;
  created_at: string;
  updated_at: string;
  posts: { title: string | null; archived_at: string | null } | null;
};

function fmtKES(n: number) {
  return `KES ${(n / 100).toLocaleString("en-KE", { minimumFractionDigits: 2 })}`;
}

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

// Transaction statuses that represent funds currently held in escrow.
// 'paid' = STK confirmed, locked; 'payout_pending' = B2C in-flight; 'disputed' = frozen.
const ESCROW_STATUSES = ["paid", "payout_pending", "disputed"];

async function getData() {
  const db = createServiceClient();
  const { data } = await db
    .from("transactions")
    .select("id, post_id, buyer_user_id, amount, total_paid, status, mpesa_receipt, created_at, posts(title, archived_at)")
    .in("status", ["paid", "payout_pending", "disputed"])
    .order("created_at", { ascending: false })
    .limit(300);
  return (data ?? []) as unknown as TxRow[];
}

const STATUS_COLORS: Record<string, string> = {
  paid: "bg-blue-100 text-blue-700",
  payout_pending: "bg-orange-100 text-orange-700",
  disputed: "bg-red-100 text-red-700",
};

export default async function EscrowStatusPage() {
  const rows = await getData();
  const locked = rows.reduce((s, r) => s + (r.total_paid ?? 0), 0);

  const byStatus = ESCROW_STATUSES.map((s) => ({
    status: s,
    count: rows.filter((r) => r.status === s).length,
    total: rows.filter((r) => r.status === s).reduce((sum, r) => sum + (r.total_paid ?? 0), 0),
  }));

  const columns = [
    {
      key: "id",
      label: "Transaction",
      render: (r: TxRow) => (
        <div>
          <p className="font-mono text-xs text-gray-900">{r.id.slice(0, 12)}…</p>
          {r.mpesa_receipt && <p className="text-xs text-gray-400">{r.mpesa_receipt}</p>}
        </div>
      ),
    },
    {
      key: "request",
      label: "Request",
      render: (r: TxRow) => (
        <div className="flex items-center gap-2 max-w-[240px]">
          <span className="text-gray-700 truncate">
            {r.posts?.title || r.post_id.slice(0, 12) + "…"}
          </span>
          {r.posts?.archived_at && <ArchivedBadge />}
        </div>
      ),
    },
    {
      key: "status",
      label: "Status",
      render: (r: TxRow) => (
        <span className={`badge ${STATUS_COLORS[r.status] ?? "bg-gray-100 text-gray-600"}`}>
          {r.status.replace(/_/g, " ")}
        </span>
      ),
    },
    {
      key: "total_paid",
      label: "Locked",
      render: (r: TxRow) => <span className="font-semibold text-amber-700">{fmtKES(r.total_paid)}</span>,
    },
    {
      key: "created_at",
      label: "Date",
      render: (r: TxRow) => <span className="text-gray-500 text-xs">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-3 gap-4">
        {byStatus.map((b) => (
          <div key={b.status} className="card p-4">
            <p className="text-xs text-gray-400 mb-1 capitalize">{b.status.replace(/_/g, " ")}</p>
            <p className="text-xl font-bold text-gray-900">{b.count}</p>
            <p className="text-sm text-amber-600 font-medium">{fmtKES(b.total)}</p>
          </div>
        ))}
      </div>

      <p className="text-sm text-gray-500">
        {rows.length} transactions · {fmtKES(locked)} in escrow
      </p>

      <DataTable columns={columns} rows={rows} emptyMessage="No escrow transactions." />
    </div>
  );
}
