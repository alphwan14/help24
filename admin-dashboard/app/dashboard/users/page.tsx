import { createServiceClient, getSessionUser } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { BanToggle } from "./BanToggle";
import { RoleToggle } from "./RoleToggle";

type UserRow = {
  id: string;
  name: string | null;
  email: string | null;
  phone_number: string | null;
  role: string | null;
  created_at: string;
  last_login: string | null;
  completed_jobs_count: number | null;
  average_rating: number | null;
  is_banned: boolean | null;
  [key: string]: unknown;
};

async function getUsers(): Promise<{ rows: UserRow[]; error: string | null }> {
  const db = createServiceClient();

  const { data, error } = await db
    .from("users")
    .select("*")                          // select * — never silently fails on missing columns
    .order("created_at", { ascending: false });

  console.log("[Users] count:", data?.length ?? 0);
  if (error) console.error("[Users] ERROR:", error.message, error.details);

  return {
    rows: (data ?? []) as UserRow[],
    error: error ? `${error.message} (${error.code})` : null,
  };
}

async function getPostCounts(): Promise<Record<string, { requests: number; offers: number }>> {
  const db = createServiceClient();
  const { data, error } = await db.from("posts").select("author_user_id, type");

  if (error) console.error("[Users/posts] ERROR:", error.message);

  const counts: Record<string, { requests: number; offers: number }> = {};
  for (const p of data ?? []) {
    const uid = p.author_user_id;
    if (!uid) continue;
    if (!counts[uid]) counts[uid] = { requests: 0, offers: 0 };
    if (p.type === "request") counts[uid].requests++;
    if (p.type === "offer") counts[uid].offers++;
  }
  return counts;
}

function fmtDate(iso: string | null) {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString("en-KE", {
    day: "2-digit",
    month: "short",
    year: "numeric",
  });
}

export default async function UsersPage() {
  const [{ rows: users, error: usersError }, postCounts, sessionUser] = await Promise.all([
    getUsers(),
    getPostCounts(),
    getSessionUser(),
  ]);

  const currentUserEmail = sessionUser?.email ?? "";

  type EnrichedUser = UserRow & { requests: number; offers: number };

  const rows: EnrichedUser[] = users.map((u) => ({
    ...u,
    requests: postCounts[u.id]?.requests ?? 0,
    offers: postCounts[u.id]?.offers ?? 0,
  }));

  const adminCount = rows.filter((r) => r.role === "admin").length;

  const columns = [
    {
      key: "name",
      label: "User",
      render: (r: EnrichedUser) => (
        <div>
          <p className="font-medium text-gray-900">{r.name || "—"}</p>
          <p className="text-xs text-gray-400">{r.email || r.id.slice(0, 12)}</p>
        </div>
      ),
    },
    {
      key: "phone_number",
      label: "Phone",
      render: (r: EnrichedUser) => <span>{r.phone_number || "—"}</span>,
    },
    {
      key: "requests",
      label: "Requests",
      render: (r: EnrichedUser) => (
        <span className="badge bg-blue-50 text-blue-700">{r.requests}</span>
      ),
    },
    {
      key: "offers",
      label: "Offers",
      render: (r: EnrichedUser) => (
        <span className="badge bg-purple-50 text-purple-700">{r.offers}</span>
      ),
    },
    {
      key: "completed_jobs_count",
      label: "Jobs Done",
      render: (r: EnrichedUser) => <span>{r.completed_jobs_count ?? 0}</span>,
    },
    {
      key: "average_rating",
      label: "Rating",
      render: (r: EnrichedUser) =>
        r.average_rating ? (
          <span className="text-amber-600 font-medium">
            ★ {Number(r.average_rating).toFixed(1)}
          </span>
        ) : (
          <span className="text-gray-400 text-xs">New</span>
        ),
    },
    {
      key: "created_at",
      label: "Joined",
      render: (r: EnrichedUser) => (
        <span className="text-gray-500">{fmtDate(r.created_at)}</span>
      ),
    },
    {
      key: "last_login",
      label: "Last Active",
      render: (r: EnrichedUser) => (
        <span className="text-gray-500">{fmtDate(r.last_login)}</span>
      ),
    },
    {
      key: "role",
      label: "Role",
      render: (r: EnrichedUser) => (
        <RoleToggle
          userId={r.id}
          userEmail={r.email ?? ""}
          initialRole={r.role ?? "user"}
          currentUserEmail={currentUserEmail}
        />
      ),
    },
    {
      key: "is_banned",
      label: "Status",
      render: (r: EnrichedUser) => (
        <BanToggle userId={r.id} isBanned={!!r.is_banned} />
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <p className="text-gray-500 text-sm">
        {rows.length} users · {adminCount} admin{adminCount !== 1 ? "s" : ""}
      </p>

      {/* Surface any DB errors visibly instead of silently showing empty table */}
      {usersError && (
        <div className="p-4 rounded-lg bg-red-50 border border-red-200 text-red-700 text-sm">
          <p className="font-semibold mb-1">Query error — check server logs</p>
          <code className="text-xs">{usersError}</code>
          <p className="mt-2 text-xs text-red-500">
            Common cause: a column referenced in the query does not exist yet.
            Run the latest Supabase migrations.
          </p>
        </div>
      )}

      <DataTable columns={columns} rows={rows} emptyMessage="No users found." />
    </div>
  );
}
