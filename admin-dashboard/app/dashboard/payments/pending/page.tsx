import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { fmtKes } from "@/lib/post-display";

type TxRow = {
  id: string;
  post_id: string;
  buyer_user_id: string | null;
  amount: number;
  total_paid: number;
  status: string;
  mpesa_receipt: string | null;
  created_at: string;
  posts: { title: string | null } | null;
};

// Money is stored in WHOLE KES, not cents: mpesa.service.ts writes
// Math.round(Number(post.price)) and fee.ts rejects anything under 100 as
// "at least 100 KES". The local helper here divided by 100, rendering a
// KES 500 payment as "KES 5.00" on every payments page. Use the one shared
// formatter instead of a sixth private copy.
const fmtKES = fmtKes;

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getPending() {
  const db = createServiceClient();
  const { data } = await db
    .from("transactions")
    .select("id, post_id, buyer_user_id, amount, total_paid, status, mpesa_receipt, created_at, posts(title)")
    .eq("status", "pending")
    .order("created_at", { ascending: false })
    .limit(200);
  return (data ?? []) as unknown as TxRow[];
}

export default async function PendingPaymentsPage() {
  const rows = await getPending();
  const total = rows.reduce((s, r) => s + (r.total_paid ?? 0), 0);

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
        <span className="text-gray-700 max-w-[180px] truncate block">
          {r.posts?.title || r.post_id.slice(0, 12) + "…"}
        </span>
      ),
    },
    {
      key: "buyer",
      label: "Buyer",
      render: (r: TxRow) => (
        <span className="font-mono text-xs text-gray-500">
          {r.buyer_user_id ? r.buyer_user_id.slice(0, 14) + "…" : "—"}
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
      render: (r: TxRow) => <span className="text-gray-500">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-4">
      <p className="text-gray-500 text-sm">
        {rows.length} pending · {fmtKES(total)} at stake
      </p>
      <DataTable columns={columns} rows={rows} emptyMessage="No pending transactions." />
    </div>
  );
}
