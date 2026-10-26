import Link from "next/link";
import { createServiceClient } from "@/lib/supabase-server";
import DataTable from "@/components/DataTable";
import { fetchAllReputations, ratingLabel, reputationByProvider } from "@/lib/reputation";
import { ACTIVITY_LABELS, ACTIVITY_MEANING, ACTIVITY_STYLES, activityState, agoLabel, lastActiveAt } from "@/lib/activity";

// Platform-wide figures, the same for every admin: cached for 60 s and rebuilt
// in the background. Without this the page was prerendered ONCE at deploy and
// served unchanged until the next deploy. Nothing here reads the session, so
// a shared cache cannot carry one admin's view to another; access is still
// decided per request by middleware before the cache is consulted.
export const revalidate = 60;

type UserRow = {
  id: string;
  name: string | null;
  email: string | null;
  phone_number: string | null;
  role: string | null;
  created_at: string;
  last_login: string | null;
  last_seen: string | null;
  is_online: boolean | null;
};

function fmtDate(iso: string | null) {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}


/**
 * Members who USED the app in the last 7 days — by the presence heartbeat
 * (last_seen, every 60 s while open) or a sign-in (last_login). It used to be
 * sign-ins only, so someone opening the app every day on a long-lived session
 * dropped off this list. Most recently active first.
 */
async function getActiveUsers(): Promise<{ rows: UserRow[]; failed: boolean }> {
  const db = createServiceClient();
  const since7 = new Date(Date.now() - 7 * 86400_000).toISOString();
  const { data, error } = await db
    .from("users")
    .select("id, name, email, phone_number, role, created_at, last_login, last_seen, is_online")
    .or(`last_login.gte.${since7},last_seen.gte.${since7}`);

  if (error) {
    console.error("[Users/active] ERROR:", error.message);
    return { rows: [], failed: true };
  }
  const rows = (data ?? []) as UserRow[];
  rows.sort((a, b) => (lastActiveAt(b) ?? -1) - (lastActiveAt(a) ?? -1));
  return { rows, failed: false };
}

export default async function ActiveUsersPage() {
  const [{ rows, failed }, reps] = await Promise.all([getActiveUsers(), fetchAllReputations()]);
  const now = Date.now();
  const repMap = reputationByProvider(reps);

  const columns = [
    {
      key: "name",
      label: "User",
      render: (r: UserRow) => (
        <div>
          <Link href={`/dashboard/users/${encodeURIComponent(r.id)}`} className="font-medium text-gray-900 hover:underline">{r.name || "—"}</Link>
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
      key: "activity",
      label: "Activity",
      render: (r: UserRow) => {
        const state = activityState(r, now);
        return (
          <span className="inline-flex flex-col gap-0.5" title={ACTIVITY_MEANING[state]}>
            <span className={`badge ${ACTIVITY_STYLES[state]} whitespace-nowrap`}>{ACTIVITY_LABELS[state]}</span>
            {state !== "online" && <span className="text-[11px] text-gray-400 tabular-nums">{agoLabel(lastActiveAt(r), now)}</span>}
          </span>
        );
      },
    },
    {
      key: "created_at",
      label: "Joined",
      render: (r: UserRow) => <span className="text-gray-500">{fmtDate(r.created_at)}</span>,
    },
  ];

  return (
    <div className="space-y-4">
      {failed ? (
        <p className="card p-4 text-sm text-gray-500">
          Activity could not be read just now. It refreshes every minute — reload to try again.
        </p>
      ) : (
        <>
          <p className="text-gray-500 text-sm">
            {rows.length} {rows.length === 1 ? "person" : "people"} used the app in the last 7 days
          </p>
          <DataTable columns={columns} rows={rows} emptyMessage="Nobody has used the app in the last 7 days." />
        </>
      )}
    </div>
  );
}
