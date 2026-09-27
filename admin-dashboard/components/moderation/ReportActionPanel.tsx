"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import ReasonDialog from "./ReasonDialog";
import SanctionDialog, { type SanctionKind } from "./SanctionDialog";
import { StatusBadge } from "./Badges";
import { resolveReportAction, triageReportAction, type TriageInput } from "@/lib/moderation-actions";
import {
  fmtDateTime,
  RESOLUTION_LABELS,
  roleAtLeast,
  SANCTION_MIN_ROLE,
  SEVERITIES,
  SEVERITY_LABELS,
  type AdminRole,
} from "@/lib/moderation-labels";

type Brief = { id: string; name: string; email: string; role: AdminRole };

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

const DISMISS_SUGGESTIONS = [
  "Not enough evidence to act on.",
  "No policy was broken.",
  "Duplicate of an earlier report.",
  "Reporter's dispute is about the job — handled in Disputes.",
];

/**
 * Everything an admin can DO about one report, and nothing they cannot.
 *
 * The rules here mirror the backend (which enforces them): a claimed case
 * belongs to its admin until a senior takes it over; reopening, reassigning
 * and heavier sanctions need seniority; a ban needs a super admin. Buttons an
 * admin cannot use are shown disabled with the reason, rather than hidden —
 * knowing a sanction exists and who can apply it is part of the job.
 */
export default function ReportActionPanel({
  report,
  reported,
  admin,
  admins,
}: {
  report: {
    id: string;
    reference: string;
    status: string;
    severity: string;
    assigned_admin: Brief | null;
    resolution: string | null;
    resolution_reason: string | null;
    resolved_at: string | null;
    resolved_by_admin: Brief | null;
  };
  reported: { id: string; name: string; status: string; isAdmin: boolean };
  admin: { id: string; role: AdminRole };
  admins: Brief[];
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [sanction, setSanction] = useState<SanctionKind | null>(null);
  const [decision, setDecision] = useState<"resolved" | "dismissed" | null>(null);
  const [severityTo, setSeverityTo] = useState<string | null>(null);
  const [reopen, setReopen] = useState(false);
  const [assignee, setAssignee] = useState("");

  const closed = report.status === "resolved" || report.status === "dismissed";
  const mine = report.assigned_admin?.id === admin.id;
  const others = !!report.assigned_admin && !mine;
  const senior = roleAtLeast(admin.role, "senior_admin");
  const locked = others && !senior;

  function triage(input: TriageInput) {
    setError(null);
    start(async () => {
      const res = await triageReportAction(report.id, input);
      if (!res.ok) setError(res.error ?? "That did not go through.");
      else router.refresh();
    });
  }

  function sanctionBlocked(kind: SanctionKind): string | null {
    const need = SANCTION_MIN_ROLE[kind];
    if (!roleAtLeast(admin.role, need)) return `Needs a ${ROLE_NAME[need]}`;
    if (reported.isAdmin && admin.role !== "super_admin") return "Admin account — super admin only";
    if (kind === "ban" && reported.status === "banned") return "Already banned";
    return null;
  }

  return (
    <div className="card p-4 space-y-4">
      <div className="flex items-center justify-between gap-2">
        <h2 className="text-[13.5px] font-semibold text-gray-900">Decision</h2>
        <StatusBadge status={report.status} />
      </div>

      {/* ── Ownership ─────────────────────────────────────────────── */}
      {!closed && (
        <div className="rounded-lg bg-gray-50 border border-gray-100 p-3 space-y-2">
          <p className="text-[12.5px] text-gray-600">
            {report.assigned_admin ? (
              <>
                Assigned to <span className="font-semibold text-gray-800">{mine ? "you" : report.assigned_admin.name || report.assigned_admin.email}</span>
              </>
            ) : (
              "Nobody has claimed this report yet."
            )}
          </p>
          <div className="flex flex-wrap gap-2">
            {!mine && (
              <button
                type="button"
                className="btn-primary !min-h-[36px] !py-1.5 text-[12.5px]"
                disabled={pending || (others && admin.role !== "super_admin")}
                title={others && admin.role !== "super_admin" ? "Only a super admin can take over a claimed report" : undefined}
                onClick={() => triage({ assign: "me", status: report.status === "new" ? "under_review" : undefined })}
              >
                {others ? "Take over" : "Claim and start review"}
              </button>
            )}
            {report.assigned_admin && (mine || senior) && (
              <button type="button" className="btn-ghost !min-h-[36px] !py-1.5 text-[12.5px] border border-gray-200" disabled={pending} onClick={() => triage({ assign: "none" })}>
                Release
              </button>
            )}
          </div>
          {senior && admins.length > 0 && (
            <div className="flex gap-2 pt-1">
              <select className="input !min-h-[36px] !py-1.5 text-[12.5px]" value={assignee} onChange={(e) => setAssignee(e.target.value)} aria-label="Assign to an admin">
                <option value="">Assign to…</option>
                {admins
                  .filter((a) => a.id !== report.assigned_admin?.id)
                  .map((a) => (
                    <option key={a.id} value={a.id}>
                      {a.name || a.email} · {ROLE_NAME[a.role]}
                    </option>
                  ))}
              </select>
              <button
                type="button"
                className="btn-ghost !min-h-[36px] !py-1.5 text-[12.5px] border border-gray-200"
                disabled={!assignee || pending}
                onClick={() => {
                  triage({ assign_to: assignee });
                  setAssignee("");
                }}
              >
                Assign
              </button>
            </div>
          )}
        </div>
      )}

      {locked && (
        <p className="text-[12.5px] text-caution-700 bg-caution-50 border border-caution-200 rounded-lg p-3">
          {report.assigned_admin?.name || report.assigned_admin?.email} is working this report. Only they or a senior admin can move, re-grade or
          close it. You can still add notes.
        </p>
      )}

      {/* ── Stage and severity ───────────────────────────────────── */}
      {!closed && (
        <div className="grid grid-cols-2 gap-2">
          <label className="block col-span-2 sm:col-span-1">
            <span className="text-[11px] font-semibold text-gray-500">Stage</span>
            <select
              className="input mt-1 !min-h-[36px] !py-1.5 text-[12.5px]"
              value={report.status === "new" ? "" : report.status}
              disabled={pending || locked}
              onChange={(e) => e.target.value && triage({ status: e.target.value as TriageInput["status"] })}
            >
              {report.status === "new" && <option value="">New — not started</option>}
              <option value="under_review">Under review</option>
              <option value="action_required">Action required</option>
            </select>
          </label>
          <label className="block col-span-2 sm:col-span-1">
            <span className="text-[11px] font-semibold text-gray-500">Severity</span>
            <select
              className="input mt-1 !min-h-[36px] !py-1.5 text-[12.5px]"
              value={report.severity}
              disabled={pending || locked}
              onChange={(e) => e.target.value !== report.severity && setSeverityTo(e.target.value)}
            >
              {SEVERITIES.map((s) => (
                <option key={s} value={s}>
                  {SEVERITY_LABELS[s]}
                </option>
              ))}
            </select>
          </label>
        </div>
      )}

      {/* ── Close the report ─────────────────────────────────────── */}
      {!closed ? (
        <div className="space-y-2">
          <p className="text-[11px] font-semibold text-gray-500 uppercase tracking-wide">Close the report</p>
          <div className="grid grid-cols-2 gap-2">
            <button type="button" className="btn-ghost !min-h-[38px] border border-gray-200 text-[12.5px]" disabled={pending || locked} onClick={() => setDecision("resolved")}>
              Resolve…
            </button>
            <button type="button" className="btn-ghost !min-h-[38px] border border-gray-200 text-[12.5px]" disabled={pending || locked} onClick={() => setDecision("dismissed")}>
              Dismiss…
            </button>
          </div>
        </div>
      ) : (
        <div className="rounded-lg bg-gray-50 border border-gray-100 p-3 space-y-1.5">
          <p className="text-[12.5px] text-gray-700">
            <span className="font-semibold">{RESOLUTION_LABELS[report.resolution ?? ""] ?? "Closed"}</span>
            {report.resolved_by_admin && <> by {report.resolved_by_admin.name || report.resolved_by_admin.email}</>}
            {report.resolved_at && <span className="text-gray-400"> · {fmtDateTime(report.resolved_at)}</span>}
          </p>
          {report.resolution_reason && <p className="text-[12.5px] text-gray-600 whitespace-pre-line">{report.resolution_reason}</p>}
          <button
            type="button"
            className="btn-ghost !min-h-[34px] !px-3 text-[12px] border border-gray-200 mt-1"
            disabled={!senior || pending}
            title={senior ? undefined : "Reopening a decision needs a senior admin"}
            onClick={() => setReopen(true)}
          >
            Reopen…
          </button>
        </div>
      )}

      {/* ── Act on the account ───────────────────────────────────── */}
      <div className="space-y-2 pt-1 border-t border-gray-100">
        <p className="text-[11px] font-semibold text-gray-500 uppercase tracking-wide pt-3">Act on {reported.name}</p>
        <div className="grid grid-cols-1 gap-1.5">
          {SANCTIONS.map((s) => {
            const blocked = sanctionBlocked(s.kind);
            return (
              <button
                key={s.kind}
                type="button"
                disabled={!!blocked || pending}
                onClick={() => setSanction(s.kind)}
                className={[
                  "flex items-center justify-between gap-2 px-3 min-h-[38px] rounded-lg border text-[12.5px] font-semibold transition-colors text-left",
                  "disabled:opacity-50 disabled:cursor-not-allowed",
                  s.danger ? "border-critical-200 text-critical-700 hover:bg-critical-50" : "border-gray-200 text-gray-700 hover:bg-gray-50",
                ].join(" ")}
              >
                <span>{s.label}…</span>
                {blocked && <span className="text-[11px] font-medium text-gray-400">{blocked}</span>}
              </button>
            );
          })}
        </div>
        <Link href={`/dashboard/trust-safety/users/${encodeURIComponent(reported.id)}`} className="inline-block text-[12.5px] font-semibold text-info-700 hover:underline pt-1">
          Full account history →
        </Link>
      </div>

      {error && <div className="p-3 rounded-lg bg-critical-50 border border-critical-200 text-[12.5px] text-critical-700">{error}</div>}

      {/* ── Dialogs ──────────────────────────────────────────────── */}
      {sanction && (
        <SanctionDialog
          open
          onClose={() => setSanction(null)}
          kind={sanction}
          userId={reported.id}
          userName={reported.name}
          reportId={report.id}
          canResolve={!closed && !locked}
        />
      )}
      <ReasonDialog
        open={decision === "resolved"}
        onClose={() => setDecision(null)}
        title={`Resolve report ${report.reference}`}
        description="Use this when the report was handled — by an action on the account, or because the situation was settled. The reporter is not told the outcome."
        reasonLabel="What was done"
        minLength={5}
        confirmLabel="Resolve report"
        onConfirm={(reason, note) => resolveReportAction(report.id, { outcome: "resolved", reason, internal_note: note })}
      />
      <ReasonDialog
        open={decision === "dismissed"}
        onClose={() => setDecision(null)}
        title={`Dismiss report ${report.reference}`}
        description="Use this when no action is warranted. The report stays on record, and still counts in the account's history."
        reasonLabel="Why no action"
        minLength={5}
        suggestions={DISMISS_SUGGESTIONS}
        confirmLabel="Dismiss report"
        onConfirm={(reason, note) => resolveReportAction(report.id, { outcome: "dismissed", reason, internal_note: note })}
      />
      <ReasonDialog
        open={!!severityTo}
        onClose={() => setSeverityTo(null)}
        title={`Change severity to ${SEVERITY_LABELS[severityTo ?? ""] ?? ""}`}
        description="Severity orders the queue. Say what changed your assessment."
        reasonLabel="Why"
        minLength={5}
        withNote={false}
        confirmLabel="Change severity"
        onConfirm={(reason) => triageReportAction(report.id, { severity: severityTo as TriageInput["severity"], reason })}
      />
      <ReasonDialog
        open={reopen}
        onClose={() => setReopen(false)}
        title={`Reopen report ${report.reference}`}
        description="The earlier decision stays in the audit log. The report returns to the queue as under review."
        reasonLabel="Why reopen"
        minLength={5}
        withNote={false}
        confirmLabel="Reopen report"
        onConfirm={(reason) => triageReportAction(report.id, { status: "under_review", reason })}
      />
    </div>
  );
}
