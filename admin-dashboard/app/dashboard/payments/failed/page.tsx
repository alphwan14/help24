import Link from "next/link";
import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { ErrorState } from "@/components/moderation/States";
import { attachBuyers, attachPosts, type TxBuyer } from "@/lib/transaction-posts";
import { paymentHref } from "@/lib/payment-status";
import { fmtKes } from "@/lib/post-display";

// Live money and job state. This page was prerendered at build time, so it
// showed the database as of the last deploy — and the alerts link here.
export const dynamic = "force-dynamic";

type TxRow = {
  id: string;
  post_id: string;
  buyer_user_id: string | null;
  amount: number;
  total_paid: number;
  mpesa_receipt: string | null;
  created_at: string;
  posts: { title: string | null } | null;
  buyer: TxBuyer;
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

async function getFailed() {
  const db = createServiceClient();
  const { data, error } = await db
    .from("transactions")
    .select("id, post_id, buyer_user_id, amount, total_paid, mpesa_receipt, created_at")
    .eq("status", "failed")
    .order("created_at", { ascending: false })
    .limit(200);
  // A failed read is reported, never rendered as an empty table.
  if (error) return { rows: [] as TxRow[], error: error.message };
  const rows = await attachBuyers(db, await attachPosts(db, (data ?? []) as unknown as Array<{ post_id: string; buyer_user_id: string | null }>));
  return { rows: rows as unknown as TxRow[], error: null as string | null };
}

export default async function FailedPaymentsPage() {
  const { rows, error: loadError } = await getFailed();
  const totalFailed = rows.reduce((s, r) => s + (r.total_paid ?? 0), 0);

  const columns = [
    {
      key: "id",
      label: "Transaction",
      render: (r: TxRow) => (
        <div>
          <Link href={paymentHref(r.id)} className="block font-mono text-xs text-info-700 hover:underline">
            {r.id.slice(0, 12)}…
          </Link>
          {r.mpesa_receipt && <p className="text-xs text-gray-400">{r.mpesa_receipt}</p>}
        </div>
      ),
    },
    {
      key: "request",
      label: "Request",
      render: (r: TxRow) => (
        <Link href={paymentHref(r.id)} className="text-gray-800 max-w-[180px] truncate block hover:underline">
          {r.posts?.title || r.post_id.slice(0, 12) + "…"}
        </Link>
      ),
    },
    {
      key: "buyer",
      label: "Paid by",
      render: (r: TxRow) =>
        r.buyer?.name || r.buyer?.email ? (
          <span className="text-gray-700 truncate inline-block max-w-[180px]">{r.buyer.name || r.buyer.email}</span>
        ) : (
          <span className="font-mono text-xs text-gray-500">
            {r.buyer_user_id ? r.buyer_user_id.slice(0, 14) + "…" : "—"}
          </span>
        ),
    },
    {
      key: "total_paid",
      label: "Amount",
      render: (r: TxRow) => <span className="font-semibold text-red-600">{fmtKES(r.total_paid)}</span>,
    },
    {
      key: "status",
      label: "Status",
      render: () => <span className="badge bg-red-100 text-red-700">Payment did not go through</span>,
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
        {rows.length} failed · {fmtKES(totalFailed)} lost
      </p>
      {loadError ? (
        <ErrorState message={`Transactions could not be loaded: ${loadError}`} />
      ) : (
        <DataTable columns={columns} rows={rows} emptyMessage="No failed transactions." />
      )}
    </div>
  );
}
