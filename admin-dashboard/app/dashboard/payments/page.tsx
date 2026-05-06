import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";

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
  posts: { title: string | null } | null;
};

const STATUS_COLORS: Record<string, string> = {
  pending: "bg-amber-100 text-amber-700",
  paid: "bg-green-100 text-green-700",
  failed: "bg-red-100 text-red-700",
  payout_pending: "bg-blue-100 text-blue-700",
  released: "bg-gray-100 text-gray-600",
};

function fmtKES(n: number) {
  return `KES ${(n / 100).toLocaleString("en-KE", { minimumFractionDigits: 2 })}`;
}

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getTransactions() {
  const db = createServiceClient();
  const { data } = await db
    .from("transactions")
    .select("id, post_id, buyer_user_id, amount, fee, total_paid, status, mpesa_receipt, created_at, posts(title)")
    .order("created_at", { ascending: false })
    .limit(200);
  return (data ?? []) as unknown as TxRow[];
}

export default async function PaymentsPage() {
  const rows = await getTransactions();

  const totalVolume = rows
    .filter((r) => ["paid", "payout_pending", "released"].includes(r.status))
    .reduce((s, r) => s + (r.total_paid ?? 0), 0);

  const columns = [
    {
      key: "id",
      label: "Transaction",
      render: (r: TxRow) => (
        <div>
          <p className="font-mono text-xs text-gray-900">{r.id.slice(0, 12)}…</p>
          {r.mpesa_receipt && (
            <p className="text-xs text-gray-400">{r.mpesa_receipt}</p>
          )}
        </div>
      ),
    },
    {
      key: "post_id",
      label: "Request",
      render: (r: TxRow) => (
        <span className="text-gray-700 max-w-[180px] truncate block">
          {r.posts?.title || r.post_id.slice(0, 12) + "…"}
        </span>
      ),
    },
    {
      key: "buyer_user_id",
      label: "Buyer",
      render: (r: TxRow) => (
        <span className="font-mono text-xs text-gray-500">
          {r.buyer_user_id ? r.buyer_user_id.slice(0, 14) + "…" : "—"}
        </span>
      ),
    },
    {
      key: "amount",
      label: "Amount",
      render: (r: TxRow) => <span>{fmtKES(r.amount)}</span>,
    },
    {
      key: "fee",
      label: "Fee",
      render: (r: TxRow) => <span className="text-gray-500">{fmtKES(r.fee)}</span>,
    },
    {
      key: "total_paid",
      label: "Total Paid",
      render: (r: TxRow) => <span className="font-semibold">{fmtKES(r.total_paid)}</span>,
    },
    {
      key: "status",
      label: "Status",
      render: (r: TxRow) => (
        <span className={`badge ${STATUS_COLORS[r.status] ?? "bg-gray-100 text-gray-600"}`}>
          {r.status}
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
    <div className="space-y-6">
      <p className="text-gray-500 text-sm">
        {rows.length} transactions · Total volume:{" "}
        <span className="font-semibold text-gray-700">{fmtKES(totalVolume)}</span>
      </p>

      {/* Status summary */}
      <div className="flex gap-2 flex-wrap">
        {["pending", "paid", "payout_pending", "released", "failed"].map((s) => {
          const count = rows.filter((r) => r.status === s).length;
          return (
            <div key={s} className={`badge ${STATUS_COLORS[s] ?? ""} py-1 px-3`}>
              {s}: {count}
            </div>
          );
        })}
      </div>

      <DataTable columns={columns} rows={rows} emptyMessage="No transactions found." />
    </div>
  );
}
