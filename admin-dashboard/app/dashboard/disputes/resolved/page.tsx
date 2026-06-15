import Link from "next/link";
import { redirect } from "next/navigation";
import DataTable from "@/components/DataTable";
import { getCurrentAdmin, getOpenDisputes, type DisputeListItem } from "@/lib/api";
import {
  normalizeStatus,
  STATUS_STYLES,
  STATUS_LABELS,
  PRIORITY_STYLES,
  formatSlaAge,
} from "@/lib/dispute-status";

export const dynamic = "force-dynamic";

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

export default async function ResolvedDisputesPage() {
  const admin = await getCurrentAdmin();
  if (!admin) redirect("/dashboard/disputes");

  const disputes = await getOpenDisputes("resolved");

  const columns = [
    {
      key: "id",
      label: "Dispute",
      render: (r: DisputeListItem) => (
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
      render: (r: DisputeListItem) => (
        <span className="text-gray-700 text-sm truncate max-w-[160px] block">
          {r.posts?.title ?? "—"}
        </span>
      ),
    },
    {
      key: "priority",
      label: "Priority",
      render: (r: DisputeListItem) => (
        <span className={`badge ${PRIORITY_STYLES[r.priority] ?? "bg-gray-100 text-gray-600"}`}>
          {r.priority}
        </span>
      ),
    },
    {
      key: "amount",
      label: "At Stake",
      render: (r: DisputeListItem) => (
        <span className="font-semibold text-amber-700 text-sm">
          {r.transactions ? fmtKES(r.transactions.amount) : "—"}
        </span>
      ),
    },
    {
      key: "resolved_at",
      label: "Resolved",
      render: (r: DisputeListItem) => (
        <span className="text-xs text-gray-500">
          {r.resolved_at ? fmtDate(r.resolved_at) : "—"}
        </span>
      ),
    },
    {
      key: "status",
      label: "Status",
      render: (r: DisputeListItem) => {
        const s = normalizeStatus(r.status);
        return <span className={`badge ${STATUS_STYLES[s]}`}>{STATUS_LABELS[s]}</span>;
      },
    },
    {
      key: "actions",
      label: "",
      render: (r: DisputeListItem) => (
        <Link
          href={`/dashboard/disputes/${r.id}`}
          className="text-xs font-semibold text-blue-600 hover:underline"
        >
          View →
        </Link>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-3">
        <Link
          href="/dashboard/disputes"
          className="text-xs text-gray-400 hover:text-gray-700"
        >
          ← Active queue
        </Link>
        <span className="text-gray-300">·</span>
        <p className="text-xs text-gray-500">
          Connected as <span className="font-semibold text-gray-700">{admin.email}</span>
        </p>
      </div>

      <p className="text-sm text-gray-500">
        {disputes.length} resolved dispute{disputes.length === 1 ? "" : "s"}
      </p>

      <DataTable
        columns={columns}
        rows={disputes}
        emptyMessage="No resolved disputes found."
      />
    </div>
  );
}
