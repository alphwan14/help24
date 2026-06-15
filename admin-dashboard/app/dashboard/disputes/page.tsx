import Link from "next/link";
import DataTable from "@/components/DataTable";
import RestoringAccess from "./RestoringAccess";
import { getCurrentAdmin, getOpenDisputes, type DisputeListItem } from "@/lib/api";
import { disconnectArbitration } from "@/lib/disputes-actions";
import {
  normalizeStatus,
  STATUS_STYLES,
  STATUS_LABELS,
  PRIORITY_STYLES,
  formatSlaAge,
} from "@/lib/dispute-status";

// Always render fresh — disputes are live operational data.
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

const FILTERS = ["open", "reviewing", "resolved", "escalated"] as const;

type PageProps = { searchParams: Promise<{ status?: string }> };

export default async function DisputesPage({ searchParams }: PageProps) {
  // 1. Authenticate against the backend (token in httpOnly cookie). If not yet
  //    connected, try to silently restore from the Supabase session first.
  const admin = await getCurrentAdmin();
  if (!admin) return <RestoringAccess />;

  // 2. Load the queue from NestJS (no direct DB access).
  const { status } = await searchParams;
  const active = status && FILTERS.includes(status as (typeof FILTERS)[number]) ? status : undefined;
  const disputes = await getOpenDisputes(active);

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
      key: "sla",
      label: "Age",
      render: (r: DisputeListItem) => {
        const breaching = r.sla_age_ms > 3 * 86_400_000 && !r.resolved_at;
        return (
          <span className={`text-xs font-semibold ${breaching ? "text-red-600" : "text-gray-500"}`}>
            {formatSlaAge(r.sla_age_ms)}
          </span>
        );
      },
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
          {r.resolved_at ? "View →" : "Review →"}
        </Link>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      {/* Connected-admin bar */}
      <div className="flex items-center justify-between flex-wrap gap-2">
        <p className="text-xs text-gray-500">
          Connected as <span className="font-semibold text-gray-700">{admin.email}</span>
          <span className="ml-2 badge bg-slate-100 text-slate-600">{admin.role}</span>
        </p>
        <form action={disconnectArbitration}>
          <button type="submit" className="text-xs text-gray-400 hover:text-red-600 hover:underline">
            Disconnect
          </button>
        </form>
      </div>

      {/* Filter tabs */}
      <div className="flex gap-2 flex-wrap">
        <Link
          href="/dashboard/disputes"
          className={`px-3 py-1.5 rounded-lg text-xs font-semibold border ${
            !active ? "bg-gray-900 text-white border-gray-900" : "bg-white text-gray-600 border-gray-200"
          }`}
        >
          Active queue
        </Link>
        {FILTERS.map((f) => (
          <Link
            key={f}
            href={`/dashboard/disputes?status=${f}`}
            className={`px-3 py-1.5 rounded-lg text-xs font-semibold border capitalize ${
              active === f ? "bg-gray-900 text-white border-gray-900" : "bg-white text-gray-600 border-gray-200"
            }`}
          >
            {f}
          </Link>
        ))}
      </div>

      <p className="text-sm text-gray-500">
        {disputes.length} {active ? `'${active}'` : "active"} dispute{disputes.length === 1 ? "" : "s"}
      </p>

      <DataTable columns={columns} rows={disputes} emptyMessage="No disputes in this view." />
    </div>
  );
}
