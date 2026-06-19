import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { ArchivedBadge } from "@/components/PostStatusBadge";

type TxRow = {
  id: string;
  post_id: string;
  buyer_user_id: string | null;
  amount: number;
  fee: number;
  total_paid: number;
  status: string;
  mpesa_receipt: string | null;
  created_at: string;
  posts: { title: string | null; archived_at: string | null } | null;
};

const STATUS_COLORS: Record<string, string> = {
  paid: "bg-green-100 text-green-700",
  payout_pending: "bg-blue-100 text-blue-700",
  released: "bg-gray-100 text-gray-600",
};

function fmtKES(n: number) {
  return `KES ${(n / 100).toLocaleString("en-KE", { minimumFractionDigits: 2 })}`;
}

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getCompleted() {
  const db = createServiceClient();
  const { data } = await db
    .from("transactions")
    .select("id, post_id, buyer_user_id, amount, fee, total_paid, status, mpesa_receipt, created_at, posts(title, archived_at)")
    .in("status", ["paid", "payout_pending", "released"])
    .order("created_at", { ascending: false })
    .limit(200);
  return (data ?? []) as unknown as TxRow[];
}

export default async function CompletedPaymentsPage() {
  const rows = await getCompleted();
  const totalVolume = rows.reduce((s, r) => s + (r.total_paid ?? 0), 0);
  const totalFees = rows.reduce((s, r) => s + (r.fee ?? 0), 0);

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
        <div className="flex items-center gap-2 max-w-[220px]">
          <span className="text-gray-700 truncate">
            {r.posts?.title || r.post_id.slice(0, 12) + "…"}
          </span>
          {r.posts?.archived_at && <ArchivedBadge />}
        </div>
      ),
    },
    {
      key: "total_paid",
      label: "Total Paid",
      render: (r: TxRow) => <span className="font-semibold">{fmtKES(r.total_paid)}</span>,
    },
    {
      key: "fee",
      label: "Fee",
      render: (r: TxRow) => <span className="text-gray-500">{fmtKES(r.fee)}</span>,
    },
    {
      key: "status",
      label: "Status",
      render: (r: TxRow) => (
        <span className={`badge ${STATUS_COLORS[r.status] ?? "bg-gray-100 text-gray-600"}`}>
          {r.status.replace("_", " ")}
        </span>
      ),
    },
    {
      key: "created_at",
      label: "Date",
      render: (r: TxRow) => <span className="text-gray-500">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-4">
      <p className="text-gray-500 text-sm">
        {rows.length} transactions · {fmtKES(totalVolume)} volume · {fmtKES(totalFees)} in fees
      </p>
      <DataTable columns={columns} rows={rows} emptyMessage="No completed transactions." />
    </div>
  );
}
