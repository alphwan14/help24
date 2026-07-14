import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { ratingLabel, type ProviderRep } from "@/lib/reputation";

// Sourced from provider_reputation (server-derived, same as the mobile app) —
// the dead users.* stat columns are not read.

type CompletedRow = ProviderRep & {
  name: string | null;
  email: string | null;
  phone_number: string | null;
  created_at: string | null;
};

function fmtDate(iso: string | null) {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getCompletedProviders(): Promise<CompletedRow[]> {
  const db = createServiceClient();
  const { data: reps, error } = await db
    .from("provider_reputation")
    .select(
      "provider_id, completed_jobs, avg_rating, total_reviews, completion_rate, dispute_rate, open_disputes, tier",
    )
    .gt("completed_jobs", 0)
    .order("completed_jobs", { ascending: false })
    .limit(200);
  if (error) console.error("[marketplace/completed] ERROR:", error.message);
  const repRows = (reps ?? []) as ProviderRep[];
  if (repRows.length === 0) return [];

  const { data: users } = await db
    .from("users")
    .select("id, name, email, phone_number, created_at")
    .in("id", repRows.map((r) => r.provider_id));
  const byId = new Map((users ?? []).map((u) => [u.id, u]));

  return repRows.map((r) => {
    const u = byId.get(r.provider_id);
    return {
      ...r,
      name: u?.name ?? null,
      email: u?.email ?? null,
      phone_number: u?.phone_number ?? null,
      created_at: u?.created_at ?? null,
    };
  });
}

export default async function CompletedPage() {
  const rows = await getCompletedProviders();

  const totalCompleted = rows.reduce((s, r) => s + (r.completed_jobs ?? 0), 0);

  const columns = [
    {
      key: "name",
      label: "Provider",
      render: (r: CompletedRow) => (
        <div>
          <p className="font-medium text-gray-900">{r.name || "—"}</p>
          <p className="text-xs text-gray-400">{r.email}</p>
        </div>
      ),
    },
    {
      key: "phone_number",
      label: "Phone",
      render: (r: CompletedRow) => <span>{r.phone_number || "—"}</span>,
    },
    {
      key: "completed_jobs",
      label: "Jobs Done",
      render: (r: CompletedRow) => (
        <span className="badge bg-green-100 text-green-700 font-semibold">
          {r.completed_jobs}
        </span>
      ),
    },
    {
      key: "avg_rating",
      label: "Avg Rating",
      render: (r: CompletedRow) => {
        const label = ratingLabel(r);
        return label ? (
          <span className="text-amber-600 font-medium">{label}</span>
        ) : (
          <span className="text-gray-400 text-xs">—</span>
        );
      },
    },
    {
      key: "created_at",
      label: "Joined",
      render: (r: CompletedRow) => <span className="text-gray-500">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-4">
      <p className="text-gray-500 text-sm">
        {rows.length} provider{rows.length !== 1 ? "s" : ""} · {totalCompleted.toLocaleString("en-KE")} total jobs completed
      </p>
      <DataTable columns={columns} rows={rows} emptyMessage="No completed jobs yet." />
    </div>
  );
}
