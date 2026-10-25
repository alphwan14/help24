import RestoringAccess from "@/app/dashboard/disputes/RestoringAccess";
import {
  getCurrentAdmin,
  getAdminUsers,
  getPendingInvites,
  getUnlinkedLogins,
} from "@/lib/api";
import AdminsManager from "./AdminsManager";
import UnlinkedLogins from "./UnlinkedLogins";

// Admin management is served by the secured NestJS backend (single source of
// truth). No direct Supabase access here.
export const dynamic = "force-dynamic";

export default async function AdminsPage() {
  // 1. Authenticate against the backend (token in httpOnly cookie). If not yet
  //    connected, silently restore from the Supabase session before any prompt.
  const admin = await getCurrentAdmin();
  if (!admin) return <RestoringAccess />;

  // 2. Only super_admins manage admins / invites.
  if (admin.role !== "super_admin") {
    return (
      <div className="card p-6 max-w-md">
        <h2 className="text-base font-bold text-gray-900">Restricted</h2>
        <p className="text-sm text-gray-500 mt-1">
          Admin management requires the <span className="font-mono">super_admin</span> role.
          You are connected as{" "}
          <span className="font-semibold">{admin.email}</span>{" "}
          (<span className="font-mono">{admin.role}</span>).
        </p>
      </div>
    );
  }

  // 3. Load admins + pending invites + logins waiting to be linked. A failed
  //    unlinked-logins check is said out loud, never shown as an empty list —
  //    "nobody is waiting" and "could not check" are different facts.
  const [admins, invites, unlinked] = await Promise.all([
    getAdminUsers(),
    getPendingInvites(),
    getUnlinkedLogins().then(
      (rows) => ({ ok: true as const, rows }),
      () => ({ ok: false as const }),
    ),
  ]);

  return (
    <div className="space-y-6">
      {unlinked.ok ? (
        <UnlinkedLogins logins={unlinked.rows} />
      ) : (
        <div className="card p-4 text-sm text-amber-700 bg-amber-50 border-amber-200">
          Couldn&apos;t check for dashboard logins waiting to be linked. Reload to try again.
        </div>
      )}
      <AdminsManager
        currentAdminId={admin.id}
        currentAdminEmail={admin.email}
        currentAdminRole={admin.role}
        admins={admins}
        invites={invites}
      />
    </div>
  );
}
