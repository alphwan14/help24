import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";

type TxRow = {
  id: string;
  post_id: string;
  buyer_user_id: string | null;
  total_paid: number;
  status: string;
  mpesa_receipt: string | null;
  created_at: string;
  posts: { title: string | null } | null;
};

function fmtKES(n: number) {
  return `KES ${(n / 100).toLocaleString("en-KE", { minimumFractionDigits: 2 })}`;
}

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getRefunds() {
  const db = createServiceClient();
  const { data } = await db
    .from("transactions")
    .select("id, post_id, buyer_user_id, total_paid, status, mpesa_receipt, created_at, posts(title)")
    .in("status", ["refunded", "refund_requested", "cancelled"])
    .order("created_at", { ascending: false })
    .limit(200);
  return (data ?? []) as unknown as TxRow[];
}

const STATUS_COLORS: Record<string, string> = {
  refunded: "bg-green-100 text-green-700",
  refund_requested: "bg-yellow-100 text-yellow-700",
  cancelled: "bg-red-100 text-red-700",
};

export default async function RefundsPage() {
  const rows = await getRefunds();
  const totalRefunded = rows
    .filter((r) => r.status === "refunded")
    .reduce((s, r) => s + (r.total_paid ?? 0), 0);

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
        <span className="text-gray-700 max-w-[200px] truncate block">
          {r.posts?.title || r.post_id.slice(0, 12) + "…"}
        </span>
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
      label: "Amount",
      render: (r: TxRow) => <span className="font-semibold">{fmtKES(r.total_paid)}</span>,
    },
    {
      key: "created_at",
      label: "Date",
      render: (r: TxRow) => <span className="text-gray-500 text-xs">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-3 gap-4">
        {(["refunded", "refund_requested", "cancelled"] as const).map((s) => (
          <div key={s} className="card p-4">
            <p className="text-xs text-gray-400 mb-1 capitalize">{s.replace(/_/g, " ")}</p>
            <p className="text-2xl font-bold text-gray-900">{rows.filter((r) => r.status === s).length}</p>
          </div>
        ))}
      </div>
      <p className="text-sm text-gray-500">
        {rows.length} total · {fmtKES(totalRefunded)} refunded
      </p>
      <DataTable columns={columns} rows={rows} emptyMessage="No refund records found." />
    </div>
  );
}
