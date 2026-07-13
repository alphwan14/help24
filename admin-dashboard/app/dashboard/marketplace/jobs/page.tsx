import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { PostStatusBadge, archivedRowClass } from "@/components/PostStatusBadge";
import { jobSalaryLabel, schemasByName, smartAnswerLines, type Json } from "@/lib/post-display";

// Hiring posts (type='job') — recruitment listings from the Smart Posting
// job journey. Previously these had NO admin surface at all.

type HiringRow = {
  id: string;
  title: string;
  category: string;
  location: string;
  price: number;
  pricing_type: string;
  employment_type: string | null;
  status: string;
  archived_at: string | null;
  author_user_id: string | null;
  created_at: string;
  attributes: Json | null;
  users: { name: string | null; email: string | null } | null;
};

const EMPLOYMENT_LABELS: Record<string, string> = {
  full_time: "Full-time",
  part_time: "Part-time",
  contract: "Contract",
  temporary: "Temporary",
};

function fmtDate(iso: string) {
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getHiringPosts() {
  const db = createServiceClient();
  const { data } = await db
    .from("posts")
    .select("id, title, category, location, price, pricing_type, employment_type, status, archived_at, author_user_id, created_at, attributes, users(name, email)")
    .eq("type", "job")
    .order("created_at", { ascending: false })
    .limit(200);
  return (data ?? []) as unknown as HiringRow[];
}

async function getSchemas() {
  const db = createServiceClient();
  const { data } = await db.from("categories").select("name, question_schema");
  return schemasByName(data ?? []);
}

export default async function MarketplaceJobsPage() {
  const [rows, schemas] = await Promise.all([getHiringPosts(), getSchemas()]);

  const columns = [
    {
      key: "title",
      label: "Role",
      render: (r: HiringRow) => {
        const answers = smartAnswerLines(
          schemas.get(r.category?.toLowerCase() ?? "") ?? null,
          "job",
          r.attributes,
        );
        return (
          <div className="max-w-xs">
            <p className="font-medium text-gray-900 truncate">{r.title}</p>
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
      key: "employer",
      label: "Employer",
      render: (r: HiringRow) => (
        <span className="text-gray-600">
          {r.users?.name || r.users?.email || r.author_user_id?.slice(0, 12) || "—"}
        </span>
      ),
    },
    {
      key: "employment_type",
      label: "Type",
      render: (r: HiringRow) => (
        <span className="badge bg-blue-100 text-blue-700">
          {EMPLOYMENT_LABELS[r.employment_type ?? ""] ?? r.employment_type ?? "—"}
        </span>
      ),
    },
    {
      key: "price",
      label: "Salary",
      render: (r: HiringRow) => (
        <span className="font-medium">{jobSalaryLabel(r.price, r.pricing_type)}</span>
      ),
    },
    {
      key: "status",
      label: "Status",
      render: (r: HiringRow) => (
        <PostStatusBadge status={r.status} archivedAt={r.archived_at} />
      ),
    },
    {
      key: "created_at",
      label: "Posted",
      render: (r: HiringRow) => <span className="text-gray-500">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-4">
      <p className="text-gray-500 text-sm">{rows.length} results</p>
      <DataTable
        columns={columns}
        rows={rows}
        emptyMessage="No hiring posts yet."
        rowClassName={(r) => archivedRowClass(r.archived_at)}
      />
    </div>
  );
}
