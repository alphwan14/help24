import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { ActiveRestrictions, AccountHeader, SignalsGrid } from "@/components/moderation/AccountPanels";
import { Avatar, CategoryLabel, LayerTag, SeverityBadge, StatusBadge, TargetTag } from "@/components/moderation/Badges";
import Ledger from "@/components/moderation/Ledger";
import NoteComposer from "@/components/moderation/NoteComposer";
import ReportActionPanel from "@/components/moderation/ReportActionPanel";
import { ErrorState } from "@/components/moderation/States";
import TargetView, { EvidenceGallery } from "@/components/moderation/TargetView";
import Timeline from "@/components/moderation/Timeline";
import { getCurrentAdmin } from "@/lib/api";
import { getReportInvestigation, listModerationAdmins, settle, type ReportInvestigation } from "@/lib/moderation-api";
import { age, CATEGORY_LABELS, fmtDate, fmtDateTime, fmtKES, humanise, roleAtLeast, STATUS_LABELS, TARGET_LABELS } from "@/lib/moderation-labels";

export const dynamic = "force-dynamic";

const BASE = "/dashboard/trust-safety";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type PageProps = { params: Promise<{ id: string }> };

export default async function ReportInvestigationPage({ params }: PageProps) {
  const { id } = await params;
  if (!UUID.test(id)) notFound();

  const admin = await getCurrentAdmin();
  if (!admin) redirect(`${BASE}/queue`);

  const senior = roleAtLeast(admin.role, "senior_admin");
  const [inv, admins] = await Promise.all([
    settle(getReportInvestigation(id)),
    senior ? settle(listModerationAdmins()) : Promise.resolve(null),
  ]);
  if (!inv.ok) {
    if (inv.status === 404 || inv.status === 400) notFound();
    return <ErrorState message={inv.error} />;
  }

  const { report, reporter, reported, target, conversation, job, related_reports, decisions, notes, timeline } = inv.data;
  const reportedName = reported.user?.name?.trim() || "Unnamed account";

  return (
    <div className="space-y-5">
      {/* ── Header ─────────────────────────────────────────────────── */}
      <div>
        <Link href={`${BASE}/queue`} className="text-[12.5px] font-semibold text-gray-500 hover:text-gray-800">
          ← Moderation queue
        </Link>
        <div className="flex flex-wrap items-center gap-2 mt-2">
          <h2 className="text-[19px] font-bold text-gray-900 tracking-tight">
            Report <span className="font-mono">{report.reference}</span>
          </h2>
          <SeverityBadge severity={report.severity} />
          <StatusBadge status={report.status} />
        </div>
        <p className="text-[13px] text-gray-500 mt-1.5">
          <span className="font-medium text-gray-700">{CATEGORY_LABELS[report.reason] ?? report.reason}</span> about{" "}
          {TARGET_LABELS[report.target_type]?.toLowerCase() ?? "account"} of{" "}
          <Link href={`${BASE}/users/${encodeURIComponent(report.reported_user_id)}`} className="font-medium text-info-700 hover:underline">
            {reportedName}
          </Link>{" "}
          · filed {fmtDateTime(report.created_at)} ({age(report.created_at)} ago)
          {report.source === "app_direct" && <span className="text-gray-400"> · from an older app version</span>}
        </p>
      </div>

      <div className="grid gap-5 items-start lg:grid-cols-[minmax(0,1fr)_340px] lg:grid-rows-[auto_1fr]">
        {/* ── Primary: what is alleged, about what ─────────────────── */}
        <div className="space-y-5 min-w-0 lg:col-start-1 lg:row-start-1">
          <Section title="The report" layer="allegation" note="What the reporter says happened — an allegation, not a finding.">
            <div className="flex flex-wrap items-center gap-2">
              <CategoryLabel category={report.reason} />
              <TargetTag type={report.target_type} />
            </div>
            {report.details ? (
              <blockquote className="mt-3 border-l-2 border-caution-300 pl-3 text-[13.5px] text-gray-800 whitespace-pre-line break-words">
                {report.details}
              </blockquote>
            ) : (
              <p className="mt-3 text-[12.5px] text-gray-400">The reporter did not add a description.</p>
            )}
            <div className="mt-4">
              <p className="text-[11px] font-semibold uppercase tracking-wide text-gray-400 mb-1.5">Attachments</p>
              <EvidenceGallery items={report.evidence ?? []} />
            </div>
          </Section>

          <Section
            title={`The reported ${TARGET_LABELS[target.type]?.toLowerCase() ?? "item"}`}
            layer="platform"
            note="Recorded by Help24 at the moment the report was filed."
          >
            <TargetView target={target} reportId={report.id} reportedUserId={report.reported_user_id} decisions={decisions} />
          </Section>
        </div>

        {/* ── Aside: decide, and who is involved ───────────────────── */}
        <aside className="space-y-5 min-w-0 lg:col-start-2 lg:row-start-1 lg:row-span-2">
          <ReportActionPanel
            report={{
              id: report.id,
              reference: report.reference,
              status: report.status,
              severity: report.severity,
              assigned_admin: report.assigned_admin,
              resolution: report.resolution,
              resolution_reason: report.resolution_reason,
              resolved_at: report.resolved_at,
              resolved_by_admin: report.resolved_by_admin,
            }}
            reported={{ id: report.reported_user_id, name: reportedName, status: reported.account.status, isAdmin: reported.user?.role === "admin" }}
            admin={{ id: admin.id, role: admin.role }}
            admins={admins?.ok ? admins.data : []}
          />

          <Card title="Reported account">
            <AccountHeader summary={reported} compact />
            <div className="mt-3">
              <ActiveRestrictions summary={reported} />
            </div>
          </Card>

          <Card title="Reporter">
            <div className="flex items-center gap-2.5">
              <Avatar name={reporter.name} src={reporter.avatar} size={32} />
              <div className="min-w-0">
                <Link href={`${BASE}/users/${encodeURIComponent(reporter.id)}`} className="text-[13px] font-medium text-info-700 hover:underline truncate block">
                  {reporter.name ?? "Unnamed account"}
                </Link>
                <p className="text-[11.5px] text-gray-400">Member since {fmtDate(reporter.member_since)}</p>
              </div>
            </div>
            <p className="text-[12px] text-gray-600 mt-2.5">
              Has filed <b className="tabular-nums">{reporter.reports_made}</b> report{reporter.reports_made === 1 ? "" : "s"}:{" "}
              <b className="tabular-nums">{reporter.reports_made_actioned}</b> led to action, <b className="tabular-nums">{reporter.reports_made_dismissed}</b>{" "}
              dismissed.
            </p>
            <p className="text-[11.5px] text-gray-400 mt-1">The reported account is never told who reported them.</p>
            {reporter.reports_made > 1 && (
              <Link href={`${BASE}/reports?reporter_id=${encodeURIComponent(reporter.id)}`} className="inline-block mt-2 text-[12px] font-semibold text-info-700 hover:underline">
                Their other reports →
              </Link>
            )}
          </Card>

          <Card title={`Other reports about ${reportedName}`} layer="allegation">
            {related_reports.length === 0 ? (
              <p className="text-[12.5px] text-gray-400">None. This is the only report about this account.</p>
            ) : (
              <>
                <ul className="divide-y divide-gray-100">
                  {related_reports.slice(0, 8).map((r) => (
                    <li key={r.id} className="py-2 first:pt-0">
                      <div className="flex items-center justify-between gap-2">
                        <Link href={`${BASE}/reports/${r.id}`} className="font-mono text-[12px] font-semibold text-info-700 hover:underline">
                          {r.reference}
                        </Link>
                        <span className="text-[11px] text-gray-400">{fmtDate(r.created_at)}</span>
                      </div>
                      <p className="text-[12.5px] text-gray-700">
                        {CATEGORY_LABELS[r.reason] ?? r.reason} · {STATUS_LABELS[r.status] ?? r.status}
                      </p>
                      <p className="text-[11px] text-gray-400">
                        {[r.same_reporter && "same reporter", r.same_target && "same item"].filter(Boolean).join(" · ") || r.target_label}
                      </p>
                    </li>
                  ))}
                </ul>
                {related_reports.length > 8 && (
                  <Link
                    href={`${BASE}/reports?reported_user_id=${encodeURIComponent(report.reported_user_id)}`}
                    className="inline-block mt-2 text-[12px] font-semibold text-info-700 hover:underline"
                  >
                    All {related_reports.length + 1} reports →
                  </Link>
                )}
              </>
            )}
          </Card>

          <Card title="Decisions on this report" layer="decision">
            <Ledger entries={decisions} empty="No decision yet." />
          </Card>

          <Card title="Internal notes">
            <Ledger entries={notes} empty="No notes yet." />
            <div className={notes.length ? "mt-4" : "mt-2"}>
              <NoteComposer reportId={report.id} />
            </div>
          </Card>
        </aside>

        {/* ── Secondary: context and chronology ────────────────────── */}
        <div className="space-y-5 min-w-0 lg:col-start-1 lg:row-start-2">
          {conversation && <ConversationSection conversation={conversation} reportedName={reportedName} />}
          {job && <JobSection job={job} />}

          <Card title="Deterministic signals">
            <SignalsGrid s={reported.signals} />
          </Card>

          <Section title="Timeline" note="Oldest first. Each entry says whether it is a platform record, an allegation, or an admin decision.">
            <Timeline events={timeline} />
          </Section>
        </div>
      </div>
    </div>
  );
}

// ── Sections ─────────────────────────────────────────────────────────────────

function Section({
  title,
  layer,
  note,
  children,
}: {
  title: string;
  layer?: "allegation" | "platform" | "decision";
  note?: string;
  children: React.ReactNode;
}) {
  return (
    <section className="card p-4 sm:p-5">
      <div className="flex flex-wrap items-center gap-2 mb-3">
        <h3 className="text-[14px] font-semibold text-gray-900">{title}</h3>
        {layer && <LayerTag layer={layer} />}
      </div>
      {note && <p className="text-[11.5px] text-gray-400 -mt-2 mb-3">{note}</p>}
      {children}
    </section>
  );
}

function Card({ title, layer, children }: { title: string; layer?: "allegation" | "platform" | "decision"; children: React.ReactNode }) {
  return (
    <section className="card p-4">
      <div className="flex items-center gap-2 mb-3">
        <h3 className="text-[13px] font-semibold text-gray-900">{title}</h3>
        {layer && <LayerTag layer={layer} />}
      </div>
      {children}
    </section>
  );
}

function ConversationSection({
  conversation,
  reportedName,
}: {
  conversation: NonNullable<ReportInvestigation["conversation"]>;
  reportedName: string;
}) {
  return (
    <Section title="Conversation" layer="platform" note={`${conversation.basis} Messages are shown as stored, including any since hidden.`}>
      {conversation.messages.length === 0 ? (
        <p className="text-[12.5px] text-gray-400">No messages.</p>
      ) : (
        <ol className="space-y-2 max-h-[520px] overflow-y-auto pr-1">
          {conversation.messages.map((m) => {
            const who = m.from === "reported" ? reportedName : m.from === "reporter" ? "Reporter" : "Other";
            return (
              <li
                key={m.id}
                className={[
                  "rounded-lg px-3 py-2 text-[13px] border",
                  m.is_reported_message
                    ? "border-critical-300 bg-critical-50"
                    : m.from === "reported"
                      ? "border-gray-100 bg-gray-50"
                      : "border-gray-100 bg-surface",
                ].join(" ")}
              >
                <div className="flex flex-wrap items-center gap-2 text-[11px]">
                  <span className={`font-semibold ${m.from === "reported" ? "text-gray-900" : "text-gray-500"}`}>{who}</span>
                  <span className="text-gray-400 tabular-nums">{fmtDateTime(m.created_at)}</span>
                  {m.is_reported_message && <span className="badge bg-critical-100 text-critical-700 !text-[10.5px]">Reported message</span>}
                  {m.deleted_for_everyone && <span className="badge bg-gray-100 text-gray-500 !text-[10.5px]">Removed for both</span>}
                </div>
                <p className="text-gray-800 mt-0.5 whitespace-pre-line break-words">{m.content || <span className="text-gray-400">({humanise(m.type)})</span>}</p>
                {m.attachment_url &&
                  (m.attachment_view_url ? (
                    <a href={m.attachment_view_url} target="_blank" rel="noopener noreferrer" className="text-[12px] text-info-700 hover:underline">
                      {m.type === "image" ? "Photo" : "Document"} (link valid 10 min)
                    </a>
                  ) : (
                    <span className="text-[12px] text-gray-400">Attachment unavailable</span>
                  ))}
              </li>
            );
          })}
        </ol>
      )}
    </Section>
  );
}

const ROLE_IN_JOB: Record<string, string> = {
  client: "posted this listing",
  selected_provider: "is the selected provider",
  applicant: "applied to this listing",
  other: "is not a party to this listing",
};

function JobSection({ job }: { job: NonNullable<ReportInvestigation["job"]> }) {
  return (
    <Section title="Job & payments" layer="platform" note="The listing this report concerns, and the money and dispute record around it.">
      <p className="text-[13px] text-gray-800">
        <span className="font-semibold">{job.post.title}</span>{" "}
        <span className="text-gray-500">
          · {humanise(job.post.type)} · {humanise(job.post.status)} · {fmtKES(job.post.price)} · {job.applications_count} application
          {job.applications_count === 1 ? "" : "s"}
        </span>
      </p>
      <p className="text-[12.5px] text-gray-500 mt-1">The reported account {ROLE_IN_JOB[job.reported_role] ?? "—"}.</p>

      <div className="grid sm:grid-cols-2 gap-3 mt-3 text-[12.5px]">
        <div className="rounded-lg border border-gray-100 p-3">
          <p className="text-[11px] font-semibold uppercase tracking-wide text-gray-400 mb-1.5">Payments</p>
          {job.transactions.length === 0 ? (
            <p className="text-gray-400">None.</p>
          ) : (
            <ul className="space-y-1">
              {job.transactions.map((t) => (
                <li key={t.id} className="flex justify-between gap-2">
                  <span className="text-gray-600">
                    {humanise(t.status)} · {fmtDate(t.created_at)}
                  </span>
                  <span className="tabular-nums text-gray-800">{fmtKES(t.total_paid ?? t.amount)}</span>
                </li>
              ))}
            </ul>
          )}
          {job.escrow.length > 0 && <p className="text-gray-500 mt-1.5">Escrow: {job.escrow.map((e) => humanise(e.status)).join(", ")}</p>}
          {job.completions.length > 0 && (
            <p className="text-gray-500 mt-0.5">Completion: {job.completions.map((c) => humanise(c.status)).join(", ")}</p>
          )}
        </div>
        <div className="rounded-lg border border-gray-100 p-3">
          <p className="text-[11px] font-semibold uppercase tracking-wide text-gray-400 mb-1.5">Disputes</p>
          {job.disputes.length === 0 ? (
            <p className="text-gray-400">None.</p>
          ) : (
            <ul className="space-y-1.5">
              {job.disputes.map((d) => (
                <li key={d.id}>
                  <Link href={`/dashboard/disputes/${d.id}`} className="font-medium text-info-700 hover:underline">
                    {humanise(d.status)} · raised by the {d.raised_by_role ?? "party"}
                  </Link>
                  <p className="text-gray-500 line-clamp-2">{d.reason}</p>
                </li>
              ))}
            </ul>
          )}
          <p className="text-[11px] text-gray-400 mt-2">
            Money questions are decided in Disputes, not here. A restricted account can still approve or dispute a job that is already paid for.
          </p>
        </div>
      </div>
    </Section>
  );
}
