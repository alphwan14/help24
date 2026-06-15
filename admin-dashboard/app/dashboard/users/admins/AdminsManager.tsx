"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import type { AdminRole, AdminUser, PendingInvite } from "@/lib/api";
import {
  sendInvite,
  revokeInvite,
  updateAdminRole,
  deactivateAdmin,
} from "@/lib/admin-actions";

const ROLES: AdminRole[] = ["support_agent", "senior_admin", "super_admin"];
const ROLE_LABELS: Record<AdminRole, string> = {
  support_agent: "Support Agent",
  senior_admin: "Senior Admin",
  super_admin: "Super Admin",
};

function fmtDate(iso: string | null) {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString("en-KE", {
    day: "2-digit",
    month: "short",
    year: "numeric",
  });
}

export default function AdminsManager({
  currentAdminId,
  currentAdminEmail,
  currentAdminRole,
  admins,
  invites,
}: {
  currentAdminId: string;
  currentAdminEmail: string;
  currentAdminRole: AdminRole;
  admins: AdminUser[];
  invites: PendingInvite[];
}) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [inviteLink, setInviteLink] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  // Invite form
  const [inviteEmail, setInviteEmail] = useState("");
  const [inviteRole, setInviteRole] = useState<AdminRole>("support_agent");

  function reset() {
    setError(null);
    setNotice(null);
  }

  function handleInvite(e: React.FormEvent) {
    e.preventDefault();
    reset();
    setInviteLink(null);
    const fd = new FormData();
    fd.set("email", inviteEmail.trim());
    fd.set("role", inviteRole);
    startTransition(async () => {
      const res = await sendInvite(fd);
      if (!res.ok || !res.data) {
        setError(res.error ?? "Could not create invite.");
        return;
      }
      setInviteLink(res.data.inviteLink);
      setInviteEmail("");
      setNotice(`Invite created for ${res.data.email}.`);
      router.refresh();
    });
  }

  function handleRoleChange(id: string, role: AdminRole) {
    reset();
    startTransition(async () => {
      const res = await updateAdminRole(id, role);
      if (!res.ok) setError(res.error ?? "Could not update role.");
      else {
        setNotice("Role updated.");
        router.refresh();
      }
    });
  }

  function handleDeactivate(id: string, email: string) {
    reset();
    if (!confirm(`Deactivate ${email}? Their access is revoked immediately.`)) return;
    startTransition(async () => {
      const res = await deactivateAdmin(id);
      if (!res.ok) setError(res.error ?? "Could not deactivate admin.");
      else {
        setNotice(`${email} deactivated.`);
        router.refresh();
      }
    });
  }

  function handleRevoke(id: string, email: string) {
    reset();
    startTransition(async () => {
      const res = await revokeInvite(id);
      if (!res.ok) setError(res.error ?? "Could not revoke invite.");
      else {
        setNotice(`Invite for ${email} revoked.`);
        router.refresh();
      }
    });
  }

  return (
    <div className="space-y-6 max-w-4xl">
      {/* Connected-as header — explicit, never hidden state. */}
      <div className="flex items-center gap-2 text-sm">
        <span className="w-2 h-2 rounded-full bg-emerald-500 shrink-0" />
        <span className="text-gray-500">Connected as</span>
        <span className="font-semibold text-gray-900">{currentAdminEmail}</span>
        <span className="badge bg-indigo-100 text-indigo-700">
          {ROLE_LABELS[currentAdminRole] ?? currentAdminRole}
        </span>
      </div>

      {/* Banners */}
      {error && (
        <div className="p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-600">{error}</div>
      )}
      {notice && (
        <div className="p-3 bg-green-50 border border-green-200 rounded-lg text-sm text-green-700">{notice}</div>
      )}

      {/* Invite form */}
      <div className="card p-5 space-y-4">
        <div>
          <h2 className="text-base font-bold text-gray-900">Invite an admin</h2>
          <p className="text-sm text-gray-500 mt-0.5">
            Admins join by invitation only. The link is single-use and expires in 7 days.
          </p>
        </div>
        <form onSubmit={handleInvite} className="flex flex-col sm:flex-row gap-3">
          <input
            type="email"
            value={inviteEmail}
            onChange={(e) => setInviteEmail(e.target.value)}
            className="input flex-1"
            placeholder="new.admin@help24.app"
            required
          />
          <select
            value={inviteRole}
            onChange={(e) => setInviteRole(e.target.value as AdminRole)}
            className="input sm:w-44"
          >
            {ROLES.map((r) => (
              <option key={r} value={r}>
                {ROLE_LABELS[r]}
              </option>
            ))}
          </select>
          <button type="submit" disabled={isPending} className="btn-primary disabled:opacity-50">
            {isPending ? "Working…" : "Send invite"}
          </button>
        </form>

        {inviteLink && (
          <div className="p-3 rounded-lg bg-amber-50 border border-amber-200">
            <p className="text-xs font-semibold text-amber-800 mb-1">Invite link — share it securely</p>
            <div className="flex gap-2">
              <code className="flex-1 text-xs bg-white border border-amber-200 rounded p-2 font-mono break-all">
                {inviteLink}
              </code>
              <button
                type="button"
                onClick={() => {
                  navigator.clipboard.writeText(inviteLink);
                  setCopied(true);
                }}
                className="shrink-0 text-xs font-semibold px-3 rounded-lg bg-amber-600 text-white hover:bg-amber-700"
              >
                {copied ? "Copied" : "Copy"}
              </button>
            </div>
          </div>
        )}
      </div>

      {/* Pending invites */}
      {invites.length > 0 && (
        <div className="card p-5">
          <h3 className="text-sm font-bold text-gray-900 mb-3">
            Pending invites ({invites.length})
          </h3>
          <ul className="divide-y divide-gray-50">
            {invites.map((inv) => (
              <li key={inv.id} className="py-2.5 flex items-center justify-between gap-3">
                <div className="min-w-0">
                  <p className="text-sm text-gray-800 truncate">{inv.email}</p>
                  <p className="text-xs text-gray-400">
                    <span className="badge bg-indigo-100 text-indigo-700 mr-2">
                      {ROLE_LABELS[inv.role]}
                    </span>
                    expires {fmtDate(inv.expires_at)}
                  </p>
                </div>
                <button
                  onClick={() => handleRevoke(inv.id, inv.email)}
                  disabled={isPending}
                  className="text-xs font-semibold text-red-600 hover:underline disabled:opacity-50"
                >
                  Revoke
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* Admins table */}
      <div className="card overflow-hidden">
        <div className="px-5 py-3 border-b border-gray-100">
          <h3 className="text-sm font-bold text-gray-900">
            Admins ({admins.length})
          </h3>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-sm min-w-[640px]">
            <thead>
              <tr className="border-b border-gray-100 bg-gray-50/80 text-left text-[11px] font-semibold text-gray-400 uppercase tracking-wider">
                <th className="px-4 py-3">Admin</th>
                <th className="px-4 py-3">Role</th>
                <th className="px-4 py-3">Status</th>
                <th className="px-4 py-3">Last active</th>
                <th className="px-4 py-3"></th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-50">
              {admins.map((a) => {
                const isSelf = a.id === currentAdminId;
                return (
                  <tr key={a.id} className="hover:bg-gray-50/60">
                    <td className="px-4 py-3">
                      <p className="font-medium text-gray-900">
                        {a.name || "—"}
                        {isSelf && <span className="ml-2 text-xs text-green-600">you</span>}
                      </p>
                      <p className="text-xs text-gray-400">{a.email}</p>
                    </td>
                    <td className="px-4 py-3">
                      <select
                        value={a.role}
                        disabled={isPending || !a.active}
                        onChange={(e) => handleRoleChange(a.id, e.target.value as AdminRole)}
                        className="input py-1 text-xs w-36 disabled:opacity-60"
                      >
                        {ROLES.map((r) => (
                          <option key={r} value={r}>
                            {ROLE_LABELS[r]}
                          </option>
                        ))}
                      </select>
                    </td>
                    <td className="px-4 py-3">
                      {a.active ? (
                        <span className="badge bg-green-100 text-green-700">active</span>
                      ) : (
                        <span className="badge bg-gray-100 text-gray-500">disabled</span>
                      )}
                    </td>
                    <td className="px-4 py-3 text-gray-500">{fmtDate(a.last_login_at)}</td>
                    <td className="px-4 py-3 text-right">
                      {a.active && !isSelf && (
                        <button
                          onClick={() => handleDeactivate(a.id, a.email)}
                          disabled={isPending}
                          className="text-xs font-semibold text-red-600 hover:underline disabled:opacity-50"
                        >
                          Deactivate
                        </button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
