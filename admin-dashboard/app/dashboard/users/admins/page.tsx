import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";

type UserRow = {
  id: string;
  name: string | null;
  email: string | null;
  phone_number: string | null;
  created_at: string;
  last_login: string | null;
};

function fmtDate(iso: string | null) {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getAdmins() {
  const db = createServiceClient();
  const { data, error } = await db
    .from("users")
    .select("id, name, email, phone_number, created_at, last_login")
    .eq("role", "admin")
    .order("created_at", { ascending: false });

  if (error) console.error("[Users/admins] ERROR:", error.message);
  return (data ?? []) as UserRow[];
}

export default async function AdminsPage() {
  const rows = await getAdmins();

  const columns = [
    {
      key: "name",
      label: "Admin",
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
      render: () => (
        <span className="badge bg-indigo-100 text-indigo-700">admin</span>
      ),
    },
    {
      key: "last_login",
      label: "Last Active",
      render: (r: UserRow) => <span className="text-gray-500">{fmtDate(r.last_login)}</span>,
    },
    {
      key: "created_at",
      label: "Joined",
      render: (r: UserRow) => <span className="text-gray-500">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-4">
      <p className="text-gray-500 text-sm">{rows.length} admin{rows.length !== 1 ? "s" : ""}</p>
      <DataTable columns={columns} rows={rows} emptyMessage="No admins yet. Promote a user from the All Users tab." />
    </div>
  );
}
