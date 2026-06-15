import RestoringAccess from "@/app/dashboard/disputes/RestoringAccess";
import {
  getCurrentAdmin,
  getAdminUsers,
  getPendingInvites,
} from "@/lib/api";
import AdminsManager from "./AdminsManager";

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

  // 3. Load admins + pending invites from the backend.
  const [admins, invites] = await Promise.all([
    getAdminUsers(),
    getPendingInvites(),
  ]);

  return (
    <AdminsManager
      currentAdminId={admin.id}
      currentAdminEmail={admin.email}
      currentAdminRole={admin.role}
      admins={admins}
      invites={invites}
    />
  );
}
