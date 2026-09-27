"use client";

import { useState } from "react";
import ReasonDialog from "./ReasonDialog";
import SanctionDialog, { type SanctionKind } from "./SanctionDialog";
import { liftRestrictionAction } from "@/lib/moderation-actions";
import { fmtDateTime, RESTRICTION_KIND_LABELS, roleAtLeast, SANCTION_MIN_ROLE, type AdminRole } from "@/lib/moderation-labels";

const SANCTIONS: Array<{ kind: SanctionKind; label: string; danger?: boolean }> = [
  { kind: "warning", label: "Warn" },
  { kind: "messaging", label: "Restrict messaging" },
  { kind: "marketplace", label: "Restrict marketplace" },
  { kind: "suspension", label: "Suspend", danger: true },
  { kind: "ban", label: "Ban", danger: true },
];

const ROLE_NAME: Record<AdminRole, string> = {
  support_agent: "support agent",
  senior_admin: "senior admin",
  super_admin: "super admin",
};

type Active = { id: string; kind: string; reference: string; ends_at: string | null };

/**
 * Account-level decisions outside any one report: sanction, or end a
 * sanction early. Lifting is senior work, and lifting a ban is super-admin
 * work — the same ladder the backend enforces.
 */
export default function AccountActionPanel({
  user,
  admin,
  active,
  openListings,
}: {
  user: { id: string; name: string; status: string; isAdmin: boolean };
  admin: { role: AdminRole };
  active: Active[];
  /** Omitted when the count is not known exactly. */
  openListings?: number;
}) {
  const [sanction, setSanction] = useState<SanctionKind | null>(null);
  const [lifting, setLifting] = useState<Active | null>(null);

  function blocked(kind: SanctionKind): string | null {
    const need = SANCTION_MIN_ROLE[kind];
    if (!roleAtLeast(admin.role, need)) return `Needs a ${ROLE_NAME[need]}`;
    if (user.isAdmin && admin.role !== "super_admin") return "Admin account — super admin only";
    if (kind === "ban" && user.status === "banned") return "Already banned";
    return null;
  }

  function liftBlocked(r: Active): string | null {
    const need: AdminRole = r.kind === "ban" ? "super_admin" : "senior_admin";
    return roleAtLeast(admin.role, need) ? null : `Needs a ${ROLE_NAME[need]}`;
  }

  return (
    <div className="card p-4 space-y-4">
      <h2 className="text-[13.5px] font-semibold text-gray-900">Act on this account</h2>

      {active.length > 0 && (
        <div className="space-y-2">
          <p className="text-[11px] font-semibold text-gray-500 uppercase tracking-wide">In force</p>
          {active.map((r) => {
            const why = liftBlocked(r);
            return (
              <div key={r.id} className="flex items-center justify-between gap-2 rounded-lg border border-gray-100 px-3 py-2">
                <div className="min-w-0">
                  <p className="text-[12.5px] font-semibold text-gray-800">{RESTRICTION_KIND_LABELS[r.kind] ?? r.kind}</p>
                  <p className="text-[11px] text-gray-400">{r.ends_at ? `until ${fmtDateTime(r.ends_at)}` : "no end date"}</p>
                </div>
                <button
                  type="button"
                  disabled={!!why}
                  title={why ?? undefined}
                  onClick={() => setLifting(r)}
                  className="shrink-0 px-2.5 min-h-[32px] rounded-lg border border-gray-200 text-[12px] font-semibold text-gray-700 hover:bg-gray-50 disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  Lift…
                </button>
              </div>
            );
          })}
        </div>
      )}

      <div className="grid grid-cols-1 gap-1.5">
        {SANCTIONS.map((s) => {
          const why = blocked(s.kind);
          return (
            <button
              key={s.kind}
              type="button"
              disabled={!!why}
              onClick={() => setSanction(s.kind)}
              className={[
                "flex items-center justify-between gap-2 px-3 min-h-[38px] rounded-lg border text-[12.5px] font-semibold transition-colors text-left",
                "disabled:opacity-50 disabled:cursor-not-allowed",
                s.danger ? "border-critical-200 text-critical-700 hover:bg-critical-50" : "border-gray-200 text-gray-700 hover:bg-gray-50",
              ].join(" ")}
            >
              <span>{s.label}…</span>
              {why && <span className="text-[11px] font-medium text-gray-400">{why}</span>}
            </button>
          );
        })}
      </div>

      {sanction && (
        <SanctionDialog open onClose={() => setSanction(null)} kind={sanction} userId={user.id} userName={user.name} openListings={openListings} />
      )}
      <ReasonDialog
        open={!!lifting}
        onClose={() => setLifting(null)}
        title={`Lift ${RESTRICTION_KIND_LABELS[lifting?.kind ?? ""]?.toLowerCase() ?? "restriction"} (${lifting?.reference ?? ""})`}
        description="It ends now, the person is told their access is restored, and the original decision stays in the audit log."
        reasonLabel="Why it is being lifted"
        placeholder="e.g. Appeal upheld: the payment screenshots were from a different account."
        confirmLabel="Lift restriction"
        onConfirm={(reason, note) => liftRestrictionAction(lifting!.id, user.id, { reason, internal_note: note })}
      />
    </div>
  );
}
