import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { fetchAllReputations, ratingLabel, reputationByProvider } from "@/lib/reputation";

type UserRow = {
  id: string;
  name: string | null;
  email: string | null;
  phone_number: string | null;
  role: string | null;
  created_at: string;
  last_login: string | null;
};

function fmtDate(iso: string | null) {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

function timeAgo(iso: string | null) {
  if (!iso) return "—";
  const diff = Date.now() - new Date(iso).getTime();
  const days = Math.floor(diff / 86400_000);
  if (days === 0) return "Today";
  if (days === 1) return "Yesterday";
  if (days < 7) return `${days}d ago`;
  if (days < 30) return `${Math.floor(days / 7)}w ago`;
  return fmtDate(iso);
}

async function getActiveUsers() {
  const db = createServiceClient();
  const since7 = new Date(Date.now() - 7 * 86400_000).toISOString();
  const { data, error } = await db
    .from("users")
    .select("id, name, email, phone_number, role, created_at, last_login")
    .gte("last_login", since7)
    .order("last_login", { ascending: false });

  if (error) console.error("[Users/active] ERROR:", error.message);
  return (data ?? []) as UserRow[];
}

export default async function ActiveUsersPage() {
  const [rows, reps] = await Promise.all([getActiveUsers(), fetchAllReputations()]);
  const repMap = reputationByProvider(reps);

  const columns = [
    {
      key: "name",
      label: "User",
      render: (r: UserRow) => (
        <div>
          <p className="font-medium text-gray-900">{r.name || "—"}</p>
          <p className="text-xs text-gray-400">{r.email || r.id.slice(0, 12)}</p>
        </div>
      ),
    },
    {
      key: "phone_number",
      label: "Phone",
      render: (r: UserRow) => <span>{r.phone_number || "—"}</span>,
    },
    {
      key: "role",
      label: "Role",
      render: (r: UserRow) => (
        <span className={`badge ${r.role === "admin" ? "bg-indigo-100 text-indigo-700" : "bg-gray-100 text-gray-600"}`}>
          {r.role ?? "user"}
        </span>
      ),
    },
    {
      key: "completed_jobs",
      label: "Jobs Done",
      render: (r: UserRow) => <span>{repMap.get(r.id)?.completed_jobs ?? 0}</span>,
    },
    {
      key: "avg_rating",
      label: "Rating",
      render: (r: UserRow) => {
        const label = ratingLabel(repMap.get(r.id));
        return label ? (
          <span className="text-amber-600 font-medium">{label}</span>
        ) : (
          <span className="text-gray-400 text-xs">New</span>
        );
      },
    },
    {
      key: "last_login",
      label: "Last Active",
      render: (r: UserRow) => (
        <span className="text-emerald-600 font-medium text-sm">{timeAgo(r.last_login)}</span>
      ),
    },
    {
      key: "created_at",
      label: "Joined",
      render: (r: UserRow) => <span className="text-gray-500">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-4">
      <p className="text-gray-500 text-sm">
        {rows.length} users active in the last 7 days
      </p>
      <DataTable columns={columns} rows={rows} emptyMessage="No active users in the last 7 days." />
    </div>
  );
}
