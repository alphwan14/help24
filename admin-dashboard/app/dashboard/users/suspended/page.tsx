import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { BanToggle } from "../BanToggle";

type UserRow = {
  id: string;
  name: string | null;
  email: string | null;
  phone_number: string | null;
  created_at: string;
  last_login: string | null;
  is_banned: boolean;
};

function fmtDate(iso: string | null) {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

async function getSuspendedUsers() {
  const db = createServiceClient();
  const { data, error } = await db
    .from("users")
    .select("id, name, email, phone_number, created_at, last_login, is_banned")
    .eq("is_banned", true)
    .order("created_at", { ascending: false });

  if (error) console.error("[Users/suspended] ERROR:", error.message);
  return (data ?? []) as UserRow[];
}

export default async function SuspendedUsersPage() {
  const rows = await getSuspendedUsers();

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
      key: "last_login",
      label: "Last Active",
      render: (r: UserRow) => <span className="text-gray-500">{fmtDate(r.last_login)}</span>,
    },
    {
      key: "created_at",
      label: "Joined",
      render: (r: UserRow) => <span className="text-gray-500">{fmtDate(r.created_at)}</span>,
    },
    {
      key: "is_banned",
      label: "Action",
      render: (r: UserRow) => <BanToggle userId={r.id} isBanned={r.is_banned} />,
    },
  ];

  return (
    <div className="space-y-4">
      <p className="text-gray-500 text-sm">{rows.length} suspended user{rows.length !== 1 ? "s" : ""}</p>
      <DataTable columns={columns} rows={rows} emptyMessage="No suspended users." />
    </div>
  );
}
