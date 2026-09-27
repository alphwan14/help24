import Link from "next/link";
import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { ErrorState } from "@/components/moderation/States";
import { PhoneLink } from "@/components/marketplace/People";
import { PostStatusBadge, archivedRowClass } from "@/components/PostStatusBadge";
import { requestBudgetLabel, schemasByName, smartAnswerLines, type Json } from "@/lib/post-display";
import { CANNOT_TAKE_WORK, loadMatchingData } from "@/lib/marketplace-people";
import { candidatesFor, countByTier, type MatchTier } from "@/lib/provider-matching";

type RequestRow = {
  id: string;
  title: string;
  description: string | null;
  category: string;
  location: string;
  latitude: number | null;
  longitude: number | null;
  price: number;
  pricing_type: string;
  urgency: string;
  status: string;
  archived_at: string | null;
  author_user_id: string | null;
  selected_provider_id: string | null;
  created_at: string;
  attributes: Json | null;
  users: { name: string | null; email: string | null; phone_number: string | null } | null;
};

const STATUS_FILTERS = ["all", "open", "assigned"] as const;
type StatusFilter = (typeof STATUS_FILTERS)[number];

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getRequests(status: StatusFilter) {
  const db = createServiceClient();
  let query = db
    .from("posts")
    .select("id, title, description, category, location, latitude, longitude, price, pricing_type, urgency, status, archived_at, author_user_id, selected_provider_id, created_at, attributes, users(name, email, phone_number)")
    .eq("type", "request")
    .order("created_at", { ascending: false })
    .limit(200);

  if (status === "open") query = query.is("selected_provider_id", null);
  if (status === "assigned") query = query.not("selected_provider_id", "is", null);

  const { data, error } = await query;
  // A failed read is an error on screen, never "No requests found."
  if (error) return { rows: [] as RequestRow[], error: error.message };
  return { rows: (data ?? []) as unknown as RequestRow[], error: null as string | null };
}

// Smart Posting: category question schemas, for resolving answer labels.
async function getSchemas() {
  const db = createServiceClient();
  const { data } = await db.from("categories").select("name, question_schema");
  return schemasByName(data ?? []);
}

/** Only an open request nobody has been chosen for needs someone found. */
function needsProvider(r: RequestRow): boolean {
  return !r.selected_provider_id && r.status === "open" && !r.archived_at;
}

/** How many people could take each request that still needs someone, by strength of evidence. */
async function getSupply(rows: RequestRow[]): Promise<Map<string, Record<MatchTier, number>>> {
  const data = await loadMatchingData();
  const out = new Map<string, Record<MatchTier, number>>();
  for (const r of rows.filter(needsProvider)) {
    const available = candidatesFor(r, data.seeds, data.registry).filter(
      (c) => !CANNOT_TAKE_WORK.has(data.status.get(c.userId) ?? "active"),
    );
    out.set(r.id, countByTier(available));
  }
  return out;
}

function SupplyCell({ counts }: { counts: Record<MatchTier, number> }) {
  if (counts.same) return <span className="badge bg-positive-100 text-positive-700">{counts.same} doing this work</span>;
  if (counts.related) return <span className="badge bg-info-100 text-info-700">{counts.related} in a related trade</span>;
  if (counts.mentions) return <span className="badge bg-gray-100 text-gray-600">{counts.mentions} possible</span>;
  return (
    <span className="text-[12.5px] font-semibold text-critical-700" title="Nobody on Help24 has a trade or open offer that fits">
      Nobody
    </span>
  );
}

export default async function MarketplaceRequestsPage({
  searchParams,
}: {
  searchParams: Promise<{ status?: string }>;
}) {
  const params = await searchParams;
  const status: StatusFilter = STATUS_FILTERS.includes(params.status as StatusFilter)
    ? (params.status as StatusFilter)
    : "all";

  const [{ rows, error: loadError }, schemas] = await Promise.all([getRequests(status), getSchemas()]);

  // A failed check is shown as a failed check — never as "Nobody".
  let supply: Map<string, Record<MatchTier, number>> | null = null;
  let supplyError: string | null = null;
  try {
    supply = await getSupply(rows);
  } catch (e) {
    supplyError = e instanceof Error ? e.message : String(e);
  }

  const columns = [
    {
      key: "title",
      label: "Title",
      render: (r: RequestRow) => {
        const answers = smartAnswerLines(
          schemas.get(r.category?.toLowerCase() ?? "") ?? null,
          "request",
          r.attributes,
        );
        return (
          <div className="max-w-xs">
            <Link href={`/dashboard/marketplace/requests/${r.id}`} className="font-medium text-gray-900 truncate block hover:underline">
              {r.title}
            </Link>
            <p className="text-xs text-gray-400">{r.category} · {r.location}</p>
            {answers.length > 0 && (
              <p className="text-xs text-indigo-500 truncate" title={answers.join("\n")}>
                {answers.join(" · ")}
              </p>
            )}
          </div>
        );
      },
    },
    {
      key: "author",
      label: "Posted By",
      render: (r: RequestRow) => (
        <div className="min-w-0">
          <p className="text-gray-600 truncate">
            {r.users?.name || r.users?.email || r.author_user_id?.slice(0, 12) || "—"}
          </p>
          <PhoneLink phone={r.users?.phone_number} compact />
        </div>
      ),
    },
    {
      key: "supply",
      label: "Could take it",
      render: (r: RequestRow) => {
        if (!needsProvider(r)) return <span className="text-gray-300">—</span>;
        const counts = supply?.get(r.id);
        if (!counts) return <span className="text-gray-300" title="Couldn't check">?</span>;
        return (
          <Link href={`/dashboard/marketplace/requests/${r.id}`} className="hover:opacity-80">
            <SupplyCell counts={counts} />
          </Link>
        );
      },
    },
    {
      key: "price",
      label: "Budget",
      render: (r: RequestRow) => (
        <span className={`font-medium ${(!r.price || r.price <= 0) ? "text-gray-500" : ""}`}>
          {requestBudgetLabel(r.price)}
        </span>
      ),
    },
    {
      key: "urgency",
      label: "Urgency",
      render: (r: RequestRow) => {
        const colors: Record<string, string> = {
          urgent: "bg-red-100 text-red-700",
          soon: "bg-amber-100 text-amber-700",
          flexible: "bg-gray-100 text-gray-600",
        };
        return (
          <span className={`badge ${colors[r.urgency] ?? "bg-gray-100 text-gray-600"}`}>{r.urgency}</span>
        );
      },
    },
    {
      key: "status",
      label: "Status",
      render: (r: RequestRow) => (
        <PostStatusBadge status={r.status} archivedAt={r.archived_at} />
      ),
    },
    {
      key: "created_at",
      label: "Posted",
      render: (r: RequestRow) => <span className="text-gray-500">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <p className="text-gray-500 text-sm">{rows.length} results</p>
        <div className="flex gap-1 bg-gray-100 rounded-lg p-1">
          {STATUS_FILTERS.map((f) => (
            <a
              key={f}
              href={`?status=${f}`}
              className={`px-4 py-1.5 rounded-md text-sm font-medium transition-colors capitalize ${
                status === f ? "bg-surface shadow-sm text-gray-900" : "text-gray-500 hover:text-gray-700"
              }`}
            >
              {f}
            </a>
          ))}
        </div>
      </div>
      {supplyError && (
        <p className="card p-3 text-[12.5px] text-critical-700">
          Couldn&apos;t work out who could take these requests ({supplyError}). The &ldquo;Could take it&rdquo; column shows ? because of
          that, not because nobody can.
        </p>
      )}
      {loadError ? (
        <ErrorState message={`Requests could not be loaded: ${loadError}`} />
      ) : (
        <DataTable
          columns={columns}
          rows={rows}
          emptyMessage="No requests found."
          rowClassName={(r) => archivedRowClass(r.archived_at)}
        />
      )}
    </div>
  );
}
