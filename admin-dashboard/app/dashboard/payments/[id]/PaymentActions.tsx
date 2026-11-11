"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import Modal, { Field } from "@/components/moderation/Modal";
import ReasonDialog from "@/components/moderation/ReasonDialog";
import { takePaymentAction } from "@/lib/transaction-actions";
import type { PaymentAction, PaymentActionId } from "@/lib/transaction-types";

const COPY: Record<Exclude<PaymentActionId, "check_mpesa" | "open_dispute">, { confirm: string; placeholder: string; suggestions: string[]; danger: boolean }> = {
  retry_payout: {
    confirm: "Send the payout",
    placeholder: "Why is it being sent again?",
    suggestions: ["The first payout failed and the provider's number is now correct", "The work was approved but no payout went out"],
    danger: false,
  },
  approve_completion: {
    confirm: "Approve and pay the provider",
    placeholder: "How do you know the work is done?",
    suggestions: ["The client confirmed by phone that the work is done", "The client is unreachable and the provider sent proof of the work"],
    danger: false,
  },
  cancel_hire: {
    confirm: "Cancel the hire",
    placeholder: "Why is the hire being cancelled?",
    suggestions: ["The client asked to choose someone else", "The provider cannot do the job"],
    danger: true,
  },
};

/**
 * The actions that fit this payment now, as the backend offered them. Each
 * opens a dialog that says what will happen and asks why; the backend checks
 * again, records it with the admin's name, and only then acts.
 */
export default function PaymentActions({
  transactionId,
  actions,
  hasProvider,
}: {
  transactionId: string;
  actions: PaymentAction[];
  hasProvider: boolean;
}) {
  const [open, setOpen] = useState<PaymentActionId | null>(null);
  const [notice, setNotice] = useState<{ text: string; disputeId?: string } | null>(null);

  if (actions.length === 0) {
    return (
      <section className="card p-4">
        <p className="text-[13px] text-gray-500">
          Nothing to do on this payment right now.
          {notice && <span className="block mt-1 text-positive-700">{notice.text}</span>}
        </p>
      </section>
    );
  }

  const current = actions.find((a) => a.id === open) ?? null;
  const done = (text: string, disputeId?: string) => setNotice({ text, disputeId });

  return (
    <section className="card p-4 space-y-3">
      <p className="text-[10.5px] font-semibold uppercase tracking-wide text-gray-400">What you can do</p>
      <div className="flex flex-wrap gap-2">
        {actions.map((a) => (
          <button
            key={a.id}
            type="button"
            disabled={!a.allowed}
            title={a.allowed ? a.explanation : a.blocked_reason ?? undefined}
            onClick={() => {
              setNotice(null);
              setOpen(a.id);
            }}
            className={[
              "px-3.5 min-h-[40px] rounded-lg text-[13px] font-semibold transition-colors disabled:opacity-40 disabled:cursor-not-allowed",
              a.id === "cancel_hire"
                ? "border border-critical-200 text-critical-700 hover:bg-critical-50"
                : "bg-brand-600 text-on-action hover:bg-brand-700",
            ].join(" ")}
          >
            {a.label}
          </button>
        ))}
      </div>
      {actions.some((a) => !a.allowed) && (
        <p className="text-[12px] text-gray-400">{actions.find((a) => !a.allowed)?.blocked_reason} Ask a senior admin.</p>
      )}
      {notice && (
        <p className="text-[13px] text-positive-700">
          {notice.text}{" "}
          {notice.disputeId && (
            <Link href={`/dashboard/disputes/${encodeURIComponent(notice.disputeId)}`} className="font-semibold text-info-700 hover:underline">
              Open the dispute
            </Link>
          )}
        </p>
      )}

      {current && current.id === "check_mpesa" && (
        <CheckMpesaDialog action={current} transactionId={transactionId} onClose={() => setOpen(null)} onDone={done} />
      )}
      {current && current.id === "open_dispute" && (
        <OpenDisputeDialog action={current} transactionId={transactionId} hasProvider={hasProvider} onClose={() => setOpen(null)} onDone={done} />
      )}
      {current && current.id !== "check_mpesa" && current.id !== "open_dispute" && (
        <ReasonDialog
          open
          onClose={() => setOpen(null)}
          title={current.label}
          description={current.explanation}
          reasonLabel="Why"
          reasonHint="Recorded with your name and role before anything happens."
          placeholder={COPY[current.id].placeholder}
          suggestions={COPY[current.id].suggestions}
          minLength={5}
          withNote={false}
          confirmLabel={COPY[current.id].confirm}
          danger={COPY[current.id].danger}
          onConfirm={async (reason) => {
            const res = await takePaymentAction(transactionId, current.id, { reason });
            if (res.ok) done(res.message ?? "Done.");
            return { ok: res.ok, error: res.error };
          }}
        />
      )}
    </section>
  );
}

function CheckMpesaDialog({
  action,
  transactionId,
  onClose,
  onDone,
}: {
  action: PaymentAction;
  transactionId: string;
  onClose: () => void;
  onDone: (text: string) => void;
}) {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <Modal
      open
      onClose={onClose}
      busy={pending}
      title={action.label}
      description={action.explanation}
      footer={
        <>
          <button type="button" onClick={onClose} disabled={pending} className="btn-ghost border border-gray-200">
            Cancel
          </button>
          <button
            type="button"
            data-autofocus
            disabled={pending}
            onClick={() =>
              start(async () => {
                setError(null);
                const res = await takePaymentAction(transactionId, "check_mpesa");
                if (!res.ok) return setError(res.error ?? "That did not go through.");
                onDone(res.message ?? "Asked M-Pesa.");
                onClose();
                router.refresh();
              })
            }
            className="inline-flex items-center justify-center px-4 rounded-lg text-sm font-semibold min-h-[44px] bg-brand-600 text-on-action hover:bg-brand-700 disabled:opacity-40"
          >
            {pending ? "Asking…" : "Ask M-Pesa"}
          </button>
        </>
      }
    >
      <p className="text-[13px] text-gray-600">This is recorded with your name. You can ask again later if M-Pesa has not answered.</p>
      {error && <div className="p-3 rounded-lg bg-critical-50 border border-critical-200 text-[13px] text-critical-700">{error}</div>}
    </Modal>
  );
}

function OpenDisputeDialog({
  action,
  transactionId,
  hasProvider,
  onClose,
  onDone,
}: {
  action: PaymentAction;
  transactionId: string;
  hasProvider: boolean;
  onClose: () => void;
  onDone: (text: string, disputeId?: string) => void;
}) {
  const router = useRouter();
  const [party, setParty] = useState<"client" | "provider" | null>(null);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const ready = party != null && reason.trim().length >= 5;

  return (
    <Modal
      open
      onClose={onClose}
      busy={pending}
      title={action.label}
      description={action.explanation}
      footer={
        <>
          <button type="button" onClick={onClose} disabled={pending} className="btn-ghost border border-gray-200">
            Cancel
          </button>
          <button
            type="button"
            disabled={!ready || pending}
            onClick={() =>
              start(async () => {
                setError(null);
                const res = await takePaymentAction(transactionId, "open_dispute", { reason, raised_by: party! });
                if (!res.ok) return setError(res.error ?? "That did not go through.");
                onDone(res.message ?? "Dispute opened.", res.dispute_id);
                onClose();
                router.refresh();
              })
            }
            className="inline-flex items-center justify-center px-4 rounded-lg text-sm font-semibold min-h-[44px] bg-brand-600 text-on-action hover:bg-brand-700 disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {pending ? "Opening…" : "Open the dispute"}
          </button>
        </>
      }
    >
      <fieldset>
        <legend className="text-xs font-semibold text-gray-600">
          Who is it for<span className="text-critical-600"> *</span>
        </legend>
        <div className="mt-2 grid grid-cols-2 gap-2">
          {(["client", "provider"] as const).map((p) => (
            <label
              key={p}
              className={[
                "flex items-center gap-2 px-3 min-h-[44px] rounded-lg border text-[13px] cursor-pointer",
                party === p ? "border-brand-600 bg-brand-50 text-gray-900" : "border-gray-200 text-gray-700",
                p === "provider" && !hasProvider ? "opacity-40 pointer-events-none" : "",
              ].join(" ")}
            >
              <input type="radio" name="party" value={p} checked={party === p} onChange={() => setParty(p)} className="sr-only" />
              {p === "client" ? "The client" : "The provider"}
            </label>
          ))}
        </div>
        <p className="text-[11.5px] text-gray-400 mt-1">The case is raised in their name. They are told it was opened by Help24.</p>
      </fieldset>
      <Field label="What is wrong" required hint="Recorded with your name and role, and shown on the case.">
        <textarea
          className="input resize-none"
          rows={3}
          maxLength={900}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="What did they tell you?"
        />
      </Field>
      {error && <div className="p-3 rounded-lg bg-critical-50 border border-critical-200 text-[13px] text-critical-700">{error}</div>}
    </Modal>
  );
}
