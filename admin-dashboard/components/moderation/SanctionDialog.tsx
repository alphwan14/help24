"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Modal, { Field } from "./Modal";
import { sanctionUserAction, type SanctionInput } from "@/lib/moderation-actions";

export type SanctionKind = SanctionInput["kind"];

const SUSPENSION_DAYS = [1, 3, 7, 14, 30, 90];
const PARTIAL_DAYS = [0, 1, 3, 7, 14, 30, 90]; // 0 = until lifted

const COPY: Record<SanctionKind, { title: (n: string) => string; body: string; confirm: string; danger: boolean }> = {
  warning: {
    title: (n) => `Warn ${n}`,
    body: "They are notified and read the reason below in the app. Nothing is restricted — a warning is a record, and a signal to the next admin who opens this account.",
    confirm: "Issue warning",
    danger: false,
  },
  suspension: {
    title: (n) => `Suspend ${n}?`,
    body: "Until it ends they cannot post, apply, hire, pay, message, review, promote, mark work done or change payout details. They can still sign in, read, approve work done for them, raise or answer disputes and contact support.",
    confirm: "Suspend account",
    danger: true,
  },
  ban: {
    title: (n) => `Ban ${n} permanently?`,
    body: "Every marketplace action is blocked with no end date. Nothing is deleted: their jobs, payments and history are kept as evidence. They can still approve work done for them, raise or answer disputes on existing jobs, and appeal to support. Only a super admin can lift a ban.",
    confirm: "Ban account",
    danger: true,
  },
  messaging: {
    title: () => "Restrict messaging",
    body: "They cannot start conversations or send messages. Posting, applying and finishing existing jobs keep working.",
    confirm: "Restrict messaging",
    danger: false,
  },
  marketplace: {
    title: () => "Restrict marketplace activity",
    body: "They cannot post, apply, hire, pay or promote. Messaging and finishing existing jobs keep working.",
    confirm: "Restrict marketplace",
    danger: false,
  },
};

export default function SanctionDialog({
  open,
  onClose,
  kind,
  userId,
  userName,
  reportId,
  canResolve = true,
  openListings,
}: {
  open: boolean;
  onClose: () => void;
  kind: SanctionKind;
  userId: string;
  userName: string;
  /** Link the sanction to this report (it appears in the report's decisions). */
  reportId?: string;
  /** Offer to close the linked report too — false when it is closed or someone else's case. */
  canResolve?: boolean;
  openListings?: number;
}) {
  const router = useRouter();
  const copy = COPY[kind];
  const [reason, setReason] = useState("");
  const [note, setNote] = useState("");
  const [days, setDays] = useState(kind === "suspension" ? 7 : 0);
  const [hide, setHide] = useState(kind === "ban");
  const offerResolve = !!reportId && canResolve && kind !== "warning";
  const [resolve, setResolve] = useState(offerResolve);
  const [confirmText, setConfirmText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  const canHide = kind === "suspension" || kind === "ban" || kind === "marketplace";
  const needsTyping = kind === "ban";
  const ready = reason.trim().length >= 10 && (!needsTyping || confirmText.trim().toUpperCase() === "BAN");

  function submit() {
    setError(null);
    start(async () => {
      const res = await sanctionUserAction(userId, {
        kind,
        reason,
        internal_note: note || undefined,
        duration_days: kind === "suspension" ? days : days > 0 ? days : undefined,
        report_id: reportId,
        resolve_report: offerResolve ? resolve : undefined,
        hide_listings: canHide ? hide : undefined,
      });
      if (!res.ok) {
        setError(res.error ?? "That did not go through.");
        return;
      }
      onClose();
      router.refresh();
    });
  }

  const endLabel =
    kind === "suspension" || days > 0
      ? new Date(Date.now() + days * 86_400_000).toLocaleDateString("en-KE", { day: "2-digit", month: "long", year: "numeric" })
      : null;

  return (
    <Modal
      open={open}
      onClose={onClose}
      busy={pending}
      tone={copy.danger ? "danger" : "neutral"}
      title={copy.title(userName)}
      description={copy.body}
      footer={
        <>
          <button type="button" onClick={onClose} disabled={pending} className="btn-ghost border border-gray-200">
            Cancel
          </button>
          <button
            type="button"
            onClick={submit}
            disabled={!ready || pending}
            className={[
              "inline-flex items-center justify-center px-4 rounded-lg text-sm font-semibold min-h-[44px] transition-colors disabled:opacity-40 disabled:cursor-not-allowed",
              copy.danger ? "bg-critical-500 text-white hover:brightness-95" : "bg-brand-600 text-on-action hover:bg-brand-700",
            ].join(" ")}
          >
            {pending ? "Recording…" : copy.confirm}
          </button>
        </>
      }
    >
      {(kind === "suspension" || kind === "messaging" || kind === "marketplace") && (
        <Field
          label={kind === "suspension" ? "Duration" : "How long"}
          required={kind === "suspension"}
          hint={endLabel ? `Ends ${endLabel}. The end is fixed by the server, not this browser's clock.` : "Stays until an admin lifts it."}
        >
          <select className="input" value={days} onChange={(e) => setDays(Number(e.target.value))}>
            {(kind === "suspension" ? SUSPENSION_DAYS : PARTIAL_DAYS).map((d) => (
              <option key={d} value={d}>
                {d === 0 ? "Until lifted" : d === 1 ? "1 day" : `${d} days`}
              </option>
            ))}
          </select>
        </Field>
      )}

      <Field
        label="Reason — shown to the person"
        required
        hint="Write it for them: which rule, and what happened. They read this in the app and may quote it in an appeal. Never name who reported them."
      >
        <textarea
          className="input resize-none"
          rows={3}
          maxLength={1000}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="e.g. Asking clients to pay outside Help24 after being warned on 12 September."
        />
      </Field>

      <Field label="Internal note — admins only" hint="Evidence you weighed, context for the next admin. Never shown to the person.">
        <textarea
          className="input resize-none"
          rows={2}
          maxLength={4000}
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="e.g. Three independent reports this month; payment screenshots in report 7F3A9C21."
        />
      </Field>

      {(canHide || offerResolve) && (
        <div className="space-y-2">
          {canHide && (
            <label className="flex items-start gap-2.5 text-[13px] text-gray-700">
              <input type="checkbox" className="mt-0.5 rounded border-gray-300" checked={hide} onChange={(e) => setHide(e.target.checked)} />
              <span>
                Hide their open listings{typeof openListings === "number" ? ` (${openListings})` : ""}
                <span className="block text-[11.5px] text-gray-400">
                  Only listings still open to applicants. Jobs in progress stay visible to the other party. Each can be restored later.
                </span>
              </span>
            </label>
          )}
          {offerResolve && (
            <label className="flex items-start gap-2.5 text-[13px] text-gray-700">
              <input type="checkbox" className="mt-0.5 rounded border-gray-300" checked={resolve} onChange={(e) => setResolve(e.target.checked)} />
              <span>Close this report as &ldquo;action taken&rdquo;</span>
            </label>
          )}
        </div>
      )}

      {needsTyping && (
        <Field label="Type BAN to confirm" required>
          <input className="input font-mono uppercase" value={confirmText} onChange={(e) => setConfirmText(e.target.value)} autoComplete="off" />
        </Field>
      )}

      {error && <div className="p-3 rounded-lg bg-critical-50 border border-critical-200 text-[13px] text-critical-700">{error}</div>}
    </Modal>
  );
}
