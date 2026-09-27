"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Modal, { Field } from "@/components/moderation/Modal";
import { applyRulingAction, recordManualSettlementAction } from "@/lib/finance-actions";
import type { DisputeMoney, ShareState } from "@/lib/finance-types";
import type { AdminRole } from "@/lib/api";

const RULING_LABELS: Record<string, string> = {
  FULL_RELEASE: "Full release to the provider",
  FULL_REFUND: "Full refund to the client",
  PARTIAL_SPLIT: "Split between both",
};

const SHARE_STYLES: Record<ShareState, { label: string; cls: string }> = {
  owed: { label: "Owed — not recorded as paid", cls: "bg-caution-100 text-caution-700" },
  paid: { label: "Recorded as paid", cls: "bg-positive-100 text-positive-700" },
  in_flight: { label: "Payment in flight", cls: "bg-info-100 text-info-700" },
  not_applicable: { label: "—", cls: "bg-gray-100 text-gray-500" },
};

function kes(n: number | null | undefined) {
  return n == null ? "—" : `KES ${Math.round(n).toLocaleString("en-KE")}`;
}
function when(iso: string | null | undefined) {
  return iso ? new Date(iso).toLocaleString("en-KE", { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" }) : "—";
}

/**
 * The money after a ruling, and the two repairs for money a ruling left
 * behind (migration 117). Both are financial decisions: senior admins only,
 * each behind a dialog that asks why — and every one lands in an append-only
 * audit with the admin's name and role.
 */
export default function MoneyPanel({ money, role }: { money: DisputeMoney; role: AdminRole }) {
  const senior = role === "senior_admin" || role === "super_admin";
  const [dialog, setDialog] = useState<null | { kind: "apply" } | { kind: "record"; direction: "provider_payout" | "client_refund"; amount: number | null }>(null);
  const r = money.ruling;
  const sandbox = money.environment === "sandbox";

  return (
    <section className="card p-4 sm:p-5 space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-[14px] font-semibold text-gray-900">Money after the ruling</h2>
        {sandbox && (
          <span className="badge bg-gray-100 text-gray-600" title="MPESA_ENV=sandbox — no real money has moved">
            Sandbox — test money
          </span>
        )}
      </div>

      <dl className="grid sm:grid-cols-3 gap-3 text-[12.5px]">
        <div>
          <dt className="text-[11px] font-semibold uppercase tracking-wide text-gray-400">Ruling on record</dt>
          <dd className="text-gray-800 mt-0.5">{r ? RULING_LABELS[r.type] ?? r.type : "None recorded"}</dd>
          {r && <dd className="text-[11.5px] text-gray-400">{when(r.decided_at)}</dd>}
        </div>
        <div>
          <dt className="text-[11px] font-semibold uppercase tracking-wide text-gray-400">Payment</dt>
          <dd className="text-gray-800 mt-0.5">
            {money.payment ? `${money.payment.status} · escrow ${money.payment.escrow_status ?? "missing"}` : "—"}
          </dd>
          {money.payment && <dd className="text-[11.5px] text-gray-400">{kes(money.payment.total_paid)} paid in</dd>}
        </div>
        <div>
          <dt className="text-[11px] font-semibold uppercase tracking-wide text-gray-400">Dispute</dt>
          <dd className="text-gray-800 mt-0.5">{money.dispute.status}</dd>
        </div>
      </dl>

      {/* A closed case whose money never moved (the retired legacy resolve path). */}
      {money.can_apply_ruling && (
        <div className="rounded-lg border border-critical-200 bg-critical-50 p-3 space-y-2">
          <p className="text-[13px] font-semibold text-critical-700">
            {money.frozen ? "The case is closed, but its money is still frozen" : "The release never went out"}
          </p>
          <p className="text-[12.5px] text-critical-700/90">
            {money.frozen
              ? "It was closed through the old resolve path, which recorded the ruling without moving the money. Applying the ruling on record does exactly what the decision engine would have done."
              : "The money was unfrozen for release, but the payout did not reach M-Pesa. Applying the ruling again retries the payout."}
          </p>
          <button
            type="button"
            disabled={!senior}
            title={senior ? undefined : "A senior admin applies rulings"}
            onClick={() => setDialog({ kind: "apply" })}
            className="px-3 min-h-[36px] rounded-lg bg-critical-500 text-white text-[12.5px] font-semibold hover:brightness-95 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {money.frozen ? "Apply the recorded ruling…" : "Retry the payout…"}
          </button>
        </div>
      )}

      {/* What each side is owed under the ruling, and whether finance recorded paying it. */}
      {(money.shares.provider_payout.state !== "not_applicable" || money.shares.client_refund.state !== "not_applicable") && (
        <div className="space-y-2">
          <p className="text-[11px] font-semibold uppercase tracking-wide text-gray-400">Paid by hand (the ruling hands these to finance)</p>
          {(["provider_payout", "client_refund"] as const).map((direction) => {
            const share = money.shares[direction];
            if (share.state === "not_applicable") return null;
            const style = SHARE_STYLES[share.state];
            return (
              <div key={direction} className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-gray-100 px-3 py-2">
                <div className="min-w-0">
                  <p className="text-[12.5px] font-medium text-gray-800">
                    {direction === "provider_payout" ? "Provider's share" : "Client refund"} · {kes(share.amount)}
                  </p>
                  <span className={`badge mt-1 ${style.cls}`}>{style.label}</span>
                </div>
                {share.state === "owed" && money.payment && (
                  <button
                    type="button"
                    disabled={!senior}
                    title={senior ? undefined : "A senior admin records settlements"}
                    onClick={() => setDialog({ kind: "record", direction, amount: share.amount })}
                    className="px-3 min-h-[34px] rounded-lg border border-gray-200 text-[12.5px] font-semibold text-gray-700 hover:bg-gray-50 disabled:opacity-50 disabled:cursor-not-allowed"
                  >
                    Record as paid…
                  </button>
                )}
              </div>
            );
          })}
        </div>
      )}

      {money.legs.length > 0 && (
        <details className="group">
          <summary className="text-[12px] font-semibold text-gray-500 cursor-pointer select-none hover:text-gray-800">
            Settlement ledger ({money.legs.length})
          </summary>
          <div className="overflow-x-auto mt-2">
            <table className="w-full text-[12px] min-w-[520px]">
              <thead>
                <tr className="text-left text-[10.5px] font-semibold uppercase tracking-wide text-gray-400">
                  <th className="py-1 pr-2">Leg</th>
                  <th className="py-1 pr-2">Rail</th>
                  <th className="py-1 pr-2">Status</th>
                  <th className="py-1 pr-2">Amount</th>
                  <th className="py-1 pr-2">Reference</th>
                  <th className="py-1">By</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-50">
                {money.legs.map((l) => (
                  <tr key={l.id} className={l.status === "voided" ? "text-gray-400 line-through" : "text-gray-700"}>
                    <td className="py-1.5 pr-2">{l.direction.replace("_", " ")}</td>
                    <td className="py-1.5 pr-2">{l.rail}</td>
                    <td className="py-1.5 pr-2">{l.status}</td>
                    <td className="py-1.5 pr-2 tabular-nums">{kes(l.amount)}</td>
                    <td className="py-1.5 pr-2 font-mono">{l.reference ?? "—"}</td>
                    <td className="py-1.5">{l.created_by}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </details>
      )}

      {money.history.length > 0 && (
        <div className="space-y-1.5">
          <p className="text-[11px] font-semibold uppercase tracking-wide text-gray-400">Finance repairs on record</p>
          <ul className="space-y-1.5">
            {money.history.map((h, i) => (
              <li key={i} className="text-[12px] text-gray-600">
                <span className="font-medium text-gray-800">
                  {h.action_type === "manual_settlement_recorded" ? "Settlement recorded" : "Ruling applied"}
                </span>{" "}
                by {h.admin_email} ({h.admin_role.replace("_", " ")}) · {when(h.created_at)}
                {h.reference && <span className="font-mono"> · ref {h.reference}</span>}
                <span className="block text-gray-500">&ldquo;{h.reason}&rdquo;</span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {dialog?.kind === "apply" && r && (
        <ApplyRulingDialog money={money} onClose={() => setDialog(null)} />
      )}
      {dialog?.kind === "record" && money.payment && (
        <RecordSettlementDialog
          disputeId={money.dispute.id}
          transactionId={money.payment.id}
          direction={dialog.direction}
          amount={dialog.amount}
          sandbox={sandbox}
          onClose={() => setDialog(null)}
        />
      )}
    </section>
  );
}

function ApplyRulingDialog({ money, onClose }: { money: DisputeMoney; onClose: () => void }) {
  const router = useRouter();
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const r = money.ruling!;
  const release = r.type === "FULL_RELEASE";

  return (
    <Modal
      open
      onClose={onClose}
      busy={pending}
      tone="danger"
      title={money.frozen ? "Apply the recorded ruling?" : "Retry the payout?"}
      description={
        release
          ? `This unfreezes the payment and sends ${kes(r.provider_amount)} to the provider through M-Pesa${money.environment === "sandbox" ? " (the Daraja sandbox — no real money)" : ""}. It can be applied once; if M-Pesa refuses, you can retry.`
          : `This marks the money refunded, exactly as the decision engine records a ${RULING_LABELS[r.type]?.toLowerCase()}. Finance then pays by hand — record each payment here once it is sent.`
      }
      footer={
        <>
          <button type="button" onClick={onClose} disabled={pending} className="btn-ghost border border-gray-200">
            Cancel
          </button>
          <button
            type="button"
            disabled={pending || reason.trim().length < 5}
            onClick={() =>
              start(async () => {
                const res = await applyRulingAction(money.dispute.id, reason);
                if (!res.ok) {
                  setError(res.error ?? "That did not go through.");
                  router.refresh();
                  return;
                }
                onClose();
                router.refresh();
              })
            }
            className="inline-flex items-center justify-center px-4 rounded-lg text-sm font-semibold min-h-[44px] bg-critical-500 text-white hover:brightness-95 disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {pending ? "Applying…" : release ? "Apply and pay out" : "Apply the ruling"}
          </button>
        </>
      }
    >
      <Field label="Why" required hint="Recorded with your name and role in the finance audit.">
        <textarea
          className="input resize-none"
          rows={3}
          maxLength={1000}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="e.g. Closed by the legacy resolve on 9 June; the release never ran."
        />
      </Field>
      {error && <div className="p-3 rounded-lg bg-critical-50 border border-critical-200 text-[13px] text-critical-700">{error}</div>}
    </Modal>
  );
}

function RecordSettlementDialog({
  disputeId,
  transactionId,
  direction,
  amount,
  sandbox,
  onClose,
}: {
  disputeId: string;
  transactionId: string;
  direction: "provider_payout" | "client_refund";
  amount: number | null;
  sandbox: boolean;
  onClose: () => void;
}) {
  const router = useRouter();
  const [reference, setReference] = useState("");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const who = direction === "provider_payout" ? "the provider" : "the client";

  return (
    <Modal
      open
      onClose={onClose}
      busy={pending}
      title={`Record ${kes(amount)} as paid to ${who}?`}
      description={`Only once finance has actually sent it. The amount comes from the ruling and cannot be changed here.${sandbox ? " M-Pesa is on the sandbox, so this would record a test payment." : ""}`}
      footer={
        <>
          <button type="button" onClick={onClose} disabled={pending} className="btn-ghost border border-gray-200">
            Cancel
          </button>
          <button
            type="button"
            disabled={pending || reference.trim().length < 3 || reason.trim().length < 5}
            onClick={() =>
              start(async () => {
                const res = await recordManualSettlementAction(transactionId, disputeId, { direction, reference, reason });
                if (!res.ok) {
                  setError(res.error ?? "That did not go through.");
                  return;
                }
                onClose();
                router.refresh();
              })
            }
            className="btn-primary"
          >
            {pending ? "Recording…" : "Record as paid"}
          </button>
        </>
      }
    >
      <Field label="Payment reference" required hint="The M-Pesa code or bank reference of the payment finance made.">
        <input className="input font-mono uppercase" maxLength={64} value={reference} onChange={(e) => setReference(e.target.value)} placeholder="e.g. QK12ABC34" />
      </Field>
      <Field label="How it was paid" required hint="Recorded with your name and role in the finance audit.">
        <textarea className="input resize-none" rows={2} maxLength={1000} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Sent from the float by M-Pesa on 27 Sep." />
      </Field>
      {error && <div className="p-3 rounded-lg bg-critical-50 border border-critical-200 text-[13px] text-critical-700">{error}</div>}
    </Modal>
  );
}
