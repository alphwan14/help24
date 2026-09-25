import { createServiceClient, getSessionUser } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { fetchAllReputations, ratingLabel, reputationByProvider } from "@/lib/reputation";
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

/**
 * A count in a table cell.
 *
 * Zero is rendered muted and un-adorned: the point of the column is to let a
 * reader find the rows that have activity, and wrapping every nought in a
 * tinted pill buries them.
 */
function Count({ n }: { n: number }) {
  return (
    <span
      className={
        n > 0
          ? "tabular-nums font-medium text-gray-900"
          : "tabular-nums text-gray-400"
      }
    >
      {n}
    </span>
  );
}

export default async function UsersPage() {
  const [{ rows: users, error: usersError }, postCounts, sessionUser, reps] = await Promise.all([
    getUsers(),
    getPostCounts(),
    getSessionUser(),
    fetchAllReputations(),
  ]);

  const currentUserEmail = sessionUser?.email ?? "";
  // Server-derived reputation (same source as the mobile app) — the users.*
  // stat columns are dead and must not be read.
  const repMap = reputationByProvider(reps);

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
      // A badge is for something worth noticing, and a zero is not. Eighteen
      // rows of tinted pills each containing "0" is thirty-six pieces of
      // chrome carrying no information; the count reads better as a figure,
      // and a real one then stands out on its own.
      render: (r: EnrichedUser) => <Count n={r.requests} />,
    },
    {
      key: "offers",
      label: "Offers",
      render: (r: EnrichedUser) => <Count n={r.offers} />,
    },
    {
      key: "completed_jobs",
      label: "Jobs Done",
      render: (r: EnrichedUser) => <span>{repMap.get(r.id)?.completed_jobs ?? 0}</span>,
    },
    {
      key: "avg_rating",
      label: "Rating",
      render: (r: EnrichedUser) => {
        const label = ratingLabel(repMap.get(r.id));
        // "New" was amber-adjacent and repeated on every row — a colour that
        // said "look here" about the one value every row shared. It is muted
        // now, so a real rating is the thing that catches the eye.
        return label ? (
          <span className="text-gray-900 font-medium tabular-nums">{label}</span>
        ) : (
          <span className="text-gray-400 text-xs">New</span>
        );
      },
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
