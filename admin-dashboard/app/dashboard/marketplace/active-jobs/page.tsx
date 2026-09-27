import Link from "next/link";
import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { PersonCell } from "@/components/marketplace/People";
import { ErrorState } from "@/components/moderation/States";
import { PostStatusBadge, archivedRowClass } from "@/components/PostStatusBadge";
import { loadPeople, type Person } from "@/lib/marketplace-people";
import { requestBudgetLabel } from "@/lib/post-display";

// Live money and job state. This page was prerendered at build time, so it
// showed the database as of the last deploy — and the alerts link here.
export const dynamic = "force-dynamic";

type JobRow = {
  id: string;
  title: string;
  category: string;
  location: string;
  price: number;
  pricing_type: string;
  status: string;
  archived_at: string | null;
  author_user_id: string | null;
  selected_provider_id: string | null;
  created_at: string;
};

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getActiveJobs() {
  const db = createServiceClient();
  const { data, error } = await db
    .from("posts")
    .select("id, title, category, location, price, pricing_type, status, archived_at, author_user_id, selected_provider_id, created_at")
    .eq("type", "request")
    .not("selected_provider_id", "is", null)
    .order("created_at", { ascending: false })
    .limit(200);
  // A failed read is an error on screen, never "No active jobs."
  if (error) return { rows: [] as JobRow[], error: error.message };
  return { rows: (data ?? []) as unknown as JobRow[], error: null as string | null };
}

export default async function ActiveJobsPage() {
  const { rows, error: loadError } = await getActiveJobs();

  // Both people on every job, with the number to call — the dashboard cannot
  // message users outside a dispute.
  let people = new Map<string, Person>();
  let peopleError: string | null = null;
  try {
    people = await loadPeople(rows.flatMap((r) => [r.author_user_id, r.selected_provider_id]));
  } catch (e) {
    peopleError = e instanceof Error ? e.message : String(e);
  }

  const columns = [
    {
      key: "title",
      label: "Request",
      render: (r: JobRow) => (
        <div className="max-w-xs">
          <Link href={`/dashboard/marketplace/requests/${r.id}`} className="font-medium text-gray-900 truncate block hover:underline">
            {r.title}
          </Link>
          <p className="text-xs text-gray-400">{r.category} · {r.location}</p>
        </div>
      ),
    },
    {
      key: "author",
      label: "Client",
      render: (r: JobRow) => (
        <PersonCell person={r.author_user_id ? people.get(r.author_user_id) : undefined} fallback={r.author_user_id?.slice(0, 12) ?? null} />
      ),
    },
    {
      key: "provider",
      label: "Provider",
      render: (r: JobRow) => (
        <PersonCell
          person={r.selected_provider_id ? people.get(r.selected_provider_id) : undefined}
          fallback={r.selected_provider_id ? `${r.selected_provider_id.slice(0, 12)}…` : null}
        />
      ),
    },
    {
      key: "price",
      label: "Value",
      render: (r: JobRow) => (
        <span className="font-medium">{requestBudgetLabel(r.price)}</span>
      ),
    },
    {
      key: "status",
      label: "Status",
      render: (r: JobRow) =>
        r.archived_at ? (
          <PostStatusBadge status={r.status} archivedAt={r.archived_at} />
        ) : (
          <span className="badge bg-amber-100 text-amber-700">In Progress</span>
        ),
    },
    {
      key: "created_at",
      label: "Posted",
      render: (r: JobRow) => <span className="text-gray-500">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-4">
      <p className="text-gray-500 text-sm">{rows.length} active job{rows.length !== 1 ? "s" : ""} (provider assigned)</p>
      {peopleError && (
        <p className="card p-3 text-[12.5px] text-critical-700">
          Contact details could not be loaded ({peopleError}). Numbers are missing below because of that — reload to try again.
        </p>
      )}
      {loadError ? (
        <ErrorState message={`Active jobs could not be loaded: ${loadError}`} />
      ) : (
        <DataTable
          columns={columns}
          rows={rows}
          emptyMessage="No active jobs."
          rowClassName={(r) => archivedRowClass(r.archived_at)}
        />
      )}
    </div>
  );
}
