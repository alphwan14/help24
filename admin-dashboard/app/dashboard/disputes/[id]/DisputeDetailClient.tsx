"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import type {
  AdminMe,
  DisputeCase,
  DisputeRecommendation,
} from "@/lib/api";
import {
  assignDispute,
  decideDispute,
  postDisputeMessage,
  requestDisputeEvidence,
  markEvidenceReviewed,
  type DecisionInput,
} from "@/lib/disputes-actions";
import {
  normalizeStatus,
  isTerminal,
  STATUS_STYLES,
  STATUS_LABELS,
  PRIORITY_STYLES,
  formatSlaAge,
} from "@/lib/dispute-status";
import { ArchivedBadge } from "@/components/PostStatusBadge";

type DecisionType = DecisionInput["decisionType"];

function fmtDate(iso: string) {
  return new Date(iso).toLocaleString("en-KE", {
    day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit",
  });
}
function fmtKES(n: number | null | undefined) {
  return n == null ? "—" : `KES ${n.toLocaleString("en-KE")}`;
}

const DECISION_LABELS: Record<DecisionType, string> = {
  FULL_RELEASE: "Release to Provider",
  FULL_REFUND: "Refund Client",
  PARTIAL_SPLIT: "Partial Split",
  ESCALATE: "Escalate",
};

export default function DisputeDetailClient({
  dispute,
  recommendation,
  admin,
}: {
  dispute: DisputeCase;
  recommendation: DisputeRecommendation | null;
  admin: AdminMe;
}) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const status = normalizeStatus(dispute.status);
  const terminal = isTerminal(dispute.status);
  const isOwner = dispute.assigned_admin_id === admin.id;
  const isSuper = admin.role === "super_admin";
  const canDecideFinancial = admin.role === "senior_admin" || isSuper;
  const canRule = !terminal && (isOwner || isSuper);

  const tx = dispute.transactions;
  const post = dispute.posts;
  const escrowAmount = tx?.amount ?? 0;

  // Decision form state
  const [decisionType, setDecisionType] = useState<DecisionType>("FULL_RELEASE");
  const [providerAmount, setProviderAmount] = useState("");
  const [clientRefund, setClientRefund] = useState("");
  const [reasoning, setReasoning] = useState("");
  const [message, setMessage] = useState("");
  const [internalNote, setInternalNote] = useState(false);

  // Request-evidence form state
  const [evidenceFrom, setEvidenceFrom] = useState<"client" | "provider">("client");
  const [evidenceMsg, setEvidenceMsg] = useState("");

  function run(fn: () => Promise<{ ok: boolean; error?: string }>, okMsg?: string) {
    setError(null);
    setNotice(null);
    startTransition(async () => {
      const res = await fn();
      if (!res.ok) setError(res.error ?? "Action failed.");
      else {
        if (okMsg) setNotice(okMsg);
        router.refresh();
      }
    });
  }

  function handleClaim() {
    run(() => assignDispute(dispute.id), "Case claimed.");
  }

  function handleDecision(e: React.FormEvent) {
    e.preventDefault();
    if (!reasoning.trim()) {
      setError("Reasoning is required — it is written to the immutable audit ledger.");
      return;
    }
    const input: DecisionInput = { decisionType, reasoning: reasoning.trim() };
    if (decisionType === "PARTIAL_SPLIT") {
      const pa = parseInt(providerAmount, 10);
      const cr = parseInt(clientRefund, 10);
      if (Number.isNaN(pa) || Number.isNaN(cr)) {
        setError("Enter both amounts for a partial split.");
        return;
      }
      if (pa + cr > escrowAmount) {
        setError(`Split (${pa + cr}) exceeds escrow held (${escrowAmount}).`);
        return;
      }
      input.providerAmount = pa;
      input.clientRefundAmount = cr;
    }
    run(async () => {
      const res = await decideDispute(dispute.id, input);
      return { ok: res.ok, error: res.error };
    }, "Decision recorded.");
  }

  function handleMessage(e: React.FormEvent) {
    e.preventDefault();
    if (!message.trim()) return;
    const fd = new FormData();
    fd.set("message", message.trim());
    fd.set("internal", internalNote ? "true" : "false");
    run(async () => {
      const res = await postDisputeMessage(dispute.id, fd);
      if (res.ok) setMessage("");
      return res;
    }, internalNote ? "Internal note saved (admins only)." : undefined);
  }

  function handleRequestEvidence(e: React.FormEvent) {
    e.preventDefault();
    if (!evidenceMsg.trim()) {
      setError("Describe what evidence you need from the party.");
      return;
    }
    run(async () => {
      const res = await requestDisputeEvidence(dispute.id, evidenceFrom, evidenceMsg.trim());
      if (res.ok) setEvidenceMsg("");
      return res;
    }, `Evidence requested from the ${evidenceFrom}.`);
  }

  function handleMarkReviewed(evidenceId: string) {
    run(() => markEvidenceReviewed(dispute.id, evidenceId), "Evidence marked reviewed.");
  }

  const reviewedCount = dispute.evidence.filter((e) => e.reviewed_at).length;

  return (
    <div className="space-y-6 max-w-3xl">
      {/* Header */}
      <div className="card p-5">
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="font-mono text-xs text-gray-400 mb-1">{dispute.id}</p>
            <div className="flex items-center gap-2">
              <h2 className="text-lg font-bold text-gray-900">{post?.title ?? "Unknown Job"}</h2>
              {post?.archived_at && <ArchivedBadge withSubtitle />}
            </div>
            <p className="text-sm text-gray-500 mt-1">
              Opened {fmtDate(dispute.created_at)} · age {formatSlaAge(dispute.sla_age_ms)}
            </p>
          </div>
          <div className="flex flex-col items-end gap-1.5 shrink-0">
            <span className={`badge ${STATUS_STYLES[status]}`}>{STATUS_LABELS[status]}</span>
            <span className={`badge ${PRIORITY_STYLES[dispute.priority] ?? "bg-gray-100 text-gray-600"}`}>
              {dispute.priority}
            </span>
          </div>
        </div>
      </div>

      {/* Global action banners */}
      {error && (
        <div className="p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-600">{error}</div>
      )}
      {notice && (
        <div className="p-3 bg-green-50 border border-green-200 rounded-lg text-sm text-green-700">{notice}</div>
      )}

      {/* Assignment / lock */}
      <div className="card p-4 flex items-center justify-between gap-3 flex-wrap">
        <div>
          <p className="text-xs font-semibold text-gray-400 uppercase tracking-wide">Assignment</p>
          {dispute.assigned_admin ? (
            <p className="text-sm text-gray-800 mt-1">
              {dispute.assigned_admin.name || dispute.assigned_admin.email}
              <span className="ml-2 badge bg-slate-100 text-slate-600">{dispute.assigned_admin.role}</span>
              {isOwner && <span className="ml-2 text-xs text-green-600">you</span>}
            </p>
          ) : (
            <p className="text-sm text-gray-500 mt-1">Unassigned</p>
          )}
        </div>
        {!terminal && (!dispute.assigned_admin_id || (isSuper && !isOwner)) && (
          <button onClick={handleClaim} disabled={isPending} className="btn-primary text-sm disabled:opacity-50">
            {dispute.assigned_admin_id ? "Reassign to me" : "Claim case"}
          </button>
        )}
      </div>

      {/* Parties */}
      <div className="grid grid-cols-2 gap-4">
        <div className="card p-4">
          <p className="text-xs font-semibold text-gray-400 mb-2 uppercase tracking-wide">Client (Buyer)</p>
          <p className="font-semibold text-gray-800">{dispute.buyer?.name ?? "—"}</p>
          <p className="text-sm text-gray-500">{dispute.buyer?.phone_number ?? "—"}</p>
        </div>
        <div className="card p-4">
          <p className="text-xs font-semibold text-gray-400 mb-2 uppercase tracking-wide">Provider</p>
          <p className="font-semibold text-gray-800">{dispute.provider?.name ?? "—"}</p>
          <p className="text-sm text-gray-500">{dispute.provider?.phone_number ?? "—"}</p>
        </div>
      </div>

      {/* Payment */}
      {tx && (
        <div className="card p-4">
          <p className="text-xs font-semibold text-gray-400 mb-3 uppercase tracking-wide">Payment / Escrow</p>
          <div className="grid grid-cols-3 gap-3 text-sm">
            <div><p className="text-gray-400 text-xs">Escrow Held</p><p className="font-bold text-gray-900">{fmtKES(tx.amount)}</p></div>
            <div><p className="text-gray-400 text-xs">Platform Fee</p><p className="font-semibold text-gray-700">{fmtKES(tx.fee)}</p></div>
            <div><p className="text-gray-400 text-xs">Total Paid</p><p className="font-semibold text-gray-700">{fmtKES(tx.total_paid)}</p></div>
          </div>
          <p className="text-xs text-gray-400 mt-3">
            Transaction status: <span className="font-mono">{tx.status}</span>
            {tx.mpesa_receipt && <> · Receipt <span className="font-mono">{tx.mpesa_receipt}</span></>}
          </p>
        </div>
      )}

      {/* Reason */}
      <div className="card p-4">
        <p className="text-xs font-semibold text-gray-400 mb-2 uppercase tracking-wide">
          Dispute Reason {dispute.raised_by_role && <>· raised by {dispute.raised_by_role}</>}
        </p>
        <p className="text-gray-800 text-sm leading-relaxed">{dispute.reason}</p>
        {dispute.job_completions?.provider_note && (
          <p className="text-sm text-gray-600 mt-3 border-t border-gray-100 pt-3">
            <span className="text-gray-400">Provider note: </span>
            {dispute.job_completions.provider_note}
          </p>
        )}
      </div>

      {/* Recommendation (advisory) */}
      {recommendation && (
        <div className="card p-4 border border-indigo-100 bg-indigo-50/40">
          <div className="flex items-center justify-between">
            <p className="text-xs font-semibold text-indigo-500 uppercase tracking-wide">
              Suggested · advisory only
            </p>
            <span className="badge bg-indigo-100 text-indigo-700">{recommendation.confidence}% confidence</span>
          </div>
          <p className="text-sm font-bold text-indigo-900 mt-1">
            {DECISION_LABELS[recommendation.suggested_decision]}
          </p>
          <p className="text-xs text-indigo-700/80 mt-1 leading-relaxed">{recommendation.reasoning}</p>
        </div>
      )}

      {/* Evidence gallery */}
      <div className="card p-4">
        <div className="flex items-center justify-between mb-3">
          <p className="text-xs font-semibold text-gray-400 uppercase tracking-wide">
            Evidence ({dispute.evidence.length})
          </p>
          {dispute.evidence.length > 0 && (
            <span className="badge bg-slate-100 text-slate-600">
              {reviewedCount}/{dispute.evidence.length} reviewed
            </span>
          )}
        </div>
        {dispute.evidence.length === 0 ? (
          <p className="text-sm text-gray-400">No evidence submitted.</p>
        ) : (
          <div className="grid grid-cols-2 gap-3">
            {dispute.evidence.map((e) => {
              const isImage = e.type === "image" && !!e.file_url;
              const isFile = (e.type === "image" || e.type === "document" || e.type === "video") && !!e.file_url;
              return (
                <div key={e.id} className="border border-gray-200 rounded-lg p-3 flex flex-col gap-2">
                  <div className="flex items-center justify-between gap-2">
                    <span className="badge bg-slate-100 text-slate-600">{e.uploader_type}</span>
                    {e.reviewed_at ? (
                      <span className="badge bg-green-100 text-green-700">✓ reviewed</span>
                    ) : (
                      <button
                        onClick={() => handleMarkReviewed(e.id)}
                        disabled={isPending}
                        className="text-xs text-blue-600 hover:underline disabled:opacity-40"
                      >
                        Mark reviewed
                      </button>
                    )}
                  </div>

                  {isImage ? (
                    <a href={e.file_url!} target="_blank" rel="noreferrer" className="block">
                      {/* Signed URL — short TTL, opens full-size in a new tab. */}
                      {/* eslint-disable-next-line @next/next/no-img-element */}
                      <img
                        src={e.file_url!}
                        alt={e.file_name ?? "evidence"}
                        className="w-full h-32 object-cover rounded-md bg-gray-50"
                      />
                    </a>
                  ) : isFile ? (
                    <a href={e.file_url!} target="_blank" rel="noreferrer"
                      className="text-blue-600 hover:underline text-sm break-all">
                      📄 {e.file_name ?? `${e.type} — view file`}
                    </a>
                  ) : (
                    <p className="text-sm text-gray-700">{e.content}</p>
                  )}

                  {e.content && isFile && <p className="text-xs text-gray-500">{e.content}</p>}
                  <p className="text-xs text-gray-400">
                    {e.file_name ? <span className="break-all">{e.file_name} · </span> : null}
                    {fmtDate(e.created_at)}
                  </p>
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* Request evidence (admin → party) */}
      {canRule && (
        <form onSubmit={handleRequestEvidence} className="card p-4 space-y-3">
          <p className="text-xs font-semibold text-gray-400 uppercase tracking-wide">Request Evidence</p>
          <div className="flex gap-2">
            {(["client", "provider"] as const).map((who) => (
              <button
                key={who}
                type="button"
                onClick={() => setEvidenceFrom(who)}
                className={`py-1.5 px-3 rounded-lg text-xs font-semibold border transition-all ${
                  evidenceFrom === who
                    ? "bg-gray-900 text-white border-gray-900"
                    : "bg-white text-gray-600 border-gray-200 hover:border-gray-400"
                }`}
              >
                From {who}
              </button>
            ))}
          </div>
          <textarea
            value={evidenceMsg}
            onChange={(ev) => setEvidenceMsg(ev.target.value)}
            rows={2}
            className="input w-full resize-none"
            placeholder={`What do you need from the ${evidenceFrom}? e.g. "Upload the receipt / before-and-after photos."`}
          />
          <button type="submit" disabled={isPending || !evidenceMsg.trim()}
            className="btn-primary text-sm disabled:opacity-50">
            Request from {evidenceFrom}
          </button>
        </form>
      )}

      {/* Court thread */}
      <div className="card p-4">
        <p className="text-xs font-semibold text-gray-400 mb-3 uppercase tracking-wide">Case Thread</p>
        <div className="space-y-3 max-h-72 overflow-y-auto mb-3">
          {dispute.messages.length === 0 ? (
            <p className="text-sm text-gray-400">No messages yet.</p>
          ) : (
            dispute.messages.map((m) => {
              const senderStyle =
                m.sender_type === "admin"
                  ? "bg-blue-100 text-blue-700"
                  : m.sender_type === "system"
                    ? "bg-gray-100 text-gray-500"
                    : "bg-amber-100 text-amber-700";
              return (
                <div
                  key={m.id}
                  className={`text-sm ${m.internal ? "bg-purple-50 border border-purple-100 rounded-md p-2" : ""}`}
                >
                  <span className={`badge mr-2 ${senderStyle}`}>{m.sender_type}</span>
                  {m.internal && <span className="badge mr-2 bg-purple-100 text-purple-700">internal</span>}
                  {m.kind === "evidence_request" && (
                    <span className="badge mr-2 bg-yellow-100 text-yellow-800">evidence requested</span>
                  )}
                  {m.kind === "evidence_submitted" && (
                    <span className="badge mr-2 bg-emerald-100 text-emerald-700">evidence submitted</span>
                  )}
                  <span className="text-gray-800">{m.message}</span>
                  <span className="text-xs text-gray-400 ml-2">{fmtDate(m.created_at)}</span>
                </div>
              );
            })
          )}
        </div>
        <form onSubmit={handleMessage} className="space-y-2">
          <div className="flex gap-2">
            <input
              value={message}
              onChange={(ev) => setMessage(ev.target.value)}
              className="input flex-1"
              placeholder={internalNote ? "Internal note (admins only)…" : "Add a message to the parties…"}
            />
            <button type="submit" disabled={isPending || !message.trim()} className="btn-primary text-sm disabled:opacity-50">
              Post
            </button>
          </div>
          <label className="flex items-center gap-2 text-xs text-gray-500 select-none">
            <input
              type="checkbox"
              checked={internalNote}
              onChange={(ev) => setInternalNote(ev.target.checked)}
              className="rounded border-gray-300"
            />
            Internal note — visible to admins only (parties will not see or be notified)
          </label>
        </form>
      </div>

      {/* Immutable decision ledger */}
      {dispute.decisions.length > 0 && (
        <div className="card p-4">
          <p className="text-xs font-semibold text-gray-400 mb-2 uppercase tracking-wide">
            Decision Ledger (immutable)
          </p>
          <ul className="space-y-2">
            {dispute.decisions.map((d) => (
              <li key={d.id} className="text-sm border-l-2 border-gray-200 pl-3">
                <p className="font-semibold text-gray-800">
                  {DECISION_LABELS[d.decision_type]}
                  <span className="ml-2 text-xs text-gray-400">
                    {d.decided_by_system ? "system" : "admin"} · {fmtDate(d.created_at)}
                  </span>
                </p>
                {(d.provider_amount != null || d.client_refund_amount != null) && (
                  <p className="text-xs text-gray-500">
                    Provider {fmtKES(d.provider_amount)} · Client refund {fmtKES(d.client_refund_amount)}
                  </p>
                )}
                <p className="text-xs text-gray-600 mt-0.5">{d.reasoning}</p>
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* Decision form */}
      {terminal ? (
        <div className="card p-4 border border-gray-200 bg-gray-50 text-sm text-gray-600">
          This case is <strong>{STATUS_LABELS[status].toLowerCase()}</strong>. Decisions are immutable and
          no further rulings can be issued.
        </div>
      ) : !canRule ? (
        <div className="card p-4 border border-amber-200 bg-amber-50 text-sm text-amber-700">
          {dispute.assigned_admin_id
            ? "This case is assigned to another admin. Only they or a super_admin may rule."
            : "Claim the case before issuing a ruling."}
        </div>
      ) : (
        <form onSubmit={handleDecision} className="card p-5 space-y-4">
          <p className="text-sm font-bold text-gray-900">Issue Ruling</p>

          <div className="grid grid-cols-2 gap-2">
            {(["FULL_RELEASE", "FULL_REFUND", "PARTIAL_SPLIT", "ESCALATE"] as DecisionType[]).map((t) => {
              const financial = t !== "ESCALATE";
              const disabled = financial && !canDecideFinancial;
              return (
                <button
                  key={t}
                  type="button"
                  disabled={disabled}
                  onClick={() => setDecisionType(t)}
                  className={`py-2.5 px-3 rounded-lg text-xs font-semibold border transition-all disabled:opacity-40 disabled:cursor-not-allowed ${
                    decisionType === t ? "bg-gray-900 text-white border-gray-900" : "bg-white text-gray-600 border-gray-200 hover:border-gray-400"
                  }`}
                  title={disabled ? "Requires senior_admin or higher" : undefined}
                >
                  {DECISION_LABELS[t]}
                </button>
              );
            })}
          </div>

          {!canDecideFinancial && (
            <p className="text-xs text-amber-600">
              Your role ({admin.role}) can only ESCALATE. Financial rulings require senior_admin or higher.
            </p>
          )}

          {decisionType === "PARTIAL_SPLIT" && (
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="text-xs font-semibold text-gray-500 block mb-1">Provider Amount (KES)</label>
                <input type="number" min={0} value={providerAmount} onChange={(e) => setProviderAmount(e.target.value)}
                  className="input w-full" placeholder={String(Math.floor(escrowAmount / 2))} />
              </div>
              <div>
                <label className="text-xs font-semibold text-gray-500 block mb-1">Client Refund (KES)</label>
                <input type="number" min={0} value={clientRefund} onChange={(e) => setClientRefund(e.target.value)}
                  className="input w-full" placeholder={String(Math.ceil(escrowAmount / 2))} />
              </div>
              <p className="col-span-2 text-xs text-gray-400">Escrow held: {fmtKES(escrowAmount)} — split must not exceed this.</p>
            </div>
          )}

          <div>
            <label className="text-xs font-semibold text-gray-500 block mb-1">
              Reasoning <span className="text-red-500">*</span>
            </label>
            <textarea value={reasoning} onChange={(e) => setReasoning(e.target.value)} rows={3}
              className="input w-full resize-none"
              placeholder="Written to the immutable audit ledger and used in party notifications." />
          </div>

          <button type="submit" disabled={isPending}
            className="w-full py-3 rounded-xl font-semibold text-white text-sm bg-gray-900 hover:bg-black transition-all disabled:opacity-50">
            {isPending ? "Processing…" : `Confirm: ${DECISION_LABELS[decisionType]}`}
          </button>
        </form>
      )}
    </div>
  );
}
