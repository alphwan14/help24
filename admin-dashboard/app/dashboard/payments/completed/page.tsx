import Link from "next/link";
import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { ErrorState } from "@/components/moderation/States";
import { attachPosts } from "@/lib/transaction-posts";
import { paymentHref, paymentStatusWords } from "@/lib/payment-status";
import { fmtKes } from "@/lib/post-display";
import { ArchivedBadge } from "@/components/PostStatusBadge";

// Live money and job state. This page was prerendered at build time, so it
// showed the database as of the last deploy — and the alerts link here.
export const dynamic = "force-dynamic";

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

// Money is stored in WHOLE KES, not cents: mpesa.service.ts writes
// Math.round(Number(post.price)) and fee.ts rejects anything under 100 as
// "at least 100 KES". The local helper here divided by 100, rendering a
// KES 500 payment as "KES 5.00" on every payments page. Use the one shared
// formatter instead of a sixth private copy.
const fmtKES = fmtKes;

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getCompleted() {
  const db = createServiceClient();
  const { data, error } = await db
    .from("transactions")
    .select("id, post_id, buyer_user_id, amount, fee, total_paid, status, mpesa_receipt, created_at")
    .in("status", ["paid", "payout_pending", "released"])
    .order("created_at", { ascending: false })
    .limit(200);
  // A failed read is reported, never rendered as an empty table.
  if (error) return { rows: [] as TxRow[], error: error.message };
  const rows = await attachPosts(db, (data ?? []) as unknown as Array<{ post_id: string }>);
  return { rows: rows as unknown as TxRow[], error: null as string | null };
}

export default async function CompletedPaymentsPage() {
  const { rows, error: loadError } = await getCompleted();
  const totalVolume = rows.reduce((s, r) => s + (r.total_paid ?? 0), 0);
  const totalFees = rows.reduce((s, r) => s + (r.fee ?? 0), 0);

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
        <div className="flex items-center gap-2 max-w-[220px]">
          <Link href={paymentHref(r.id)} className="text-gray-800 truncate hover:underline">
            {r.posts?.title || r.post_id.slice(0, 12) + "…"}
          </Link>
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
          {paymentStatusWords(r.status)}
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
      {loadError ? (
        <ErrorState message={`Transactions could not be loaded: ${loadError}`} />
      ) : (
        <DataTable columns={columns} rows={rows} emptyMessage="No completed transactions." />
      )}
    </div>
  );
}
