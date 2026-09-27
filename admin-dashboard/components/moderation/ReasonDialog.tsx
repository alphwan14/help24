"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Modal, { Field } from "./Modal";
import type { ActionResult } from "@/lib/moderation-actions";

/**
 * "Tell us why, then confirm." The shared shape of every decision that is not
 * a sanction: dismissing or resolving a report, lifting a restriction, hiding
 * or restoring a listing or message.
 */
export default function ReasonDialog({
  open,
  onClose,
  title,
  description,
  reasonLabel = "Reason",
  reasonHint = "Recorded in the audit log with your name and role.",
  placeholder,
  minLength = 10,
  suggestions = [],
  withNote = true,
  confirmLabel,
  danger = false,
  onConfirm,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  description?: React.ReactNode;
  reasonLabel?: string;
  reasonHint?: string;
  placeholder?: string;
  minLength?: number;
  suggestions?: string[];
  withNote?: boolean;
  confirmLabel: string;
  danger?: boolean;
  onConfirm: (reason: string, note: string) => Promise<ActionResult>;
}) {
  const router = useRouter();
  const [reason, setReason] = useState("");
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const ready = reason.trim().length >= minLength;

  function submit() {
    setError(null);
    start(async () => {
      const res = await onConfirm(reason.trim(), note.trim());
      if (!res.ok) {
        setError(res.error ?? "That did not go through.");
        return;
      }
      setReason("");
      setNote("");
      onClose();
      router.refresh();
    });
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      busy={pending}
      tone={danger ? "danger" : "neutral"}
      title={title}
      description={description}
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
              danger ? "bg-critical-500 text-white hover:brightness-95" : "bg-brand-600 text-on-action hover:bg-brand-700",
            ].join(" ")}
          >
            {pending ? "Recording…" : confirmLabel}
          </button>
        </>
      }
    >
      <Field label={reasonLabel} required hint={reasonHint}>
        <textarea
          className="input resize-none"
          rows={3}
          maxLength={1000}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder={placeholder}
        />
      </Field>
      {suggestions.length > 0 && (
        <div className="flex flex-wrap gap-1.5 -mt-2">
          {suggestions.map((s) => (
            <button
              key={s}
              type="button"
              onClick={() => setReason(s)}
              className="px-2.5 py-1 rounded-full border border-gray-200 text-[12px] text-gray-600 hover:bg-gray-50"
            >
              {s}
            </button>
          ))}
        </div>
      )}
      {withNote && (
        <Field label="Internal note — admins only" hint="Optional context for the next admin.">
          <textarea className="input resize-none" rows={2} maxLength={4000} value={note} onChange={(e) => setNote(e.target.value)} />
        </Field>
      )}
      {error && <div className="p-3 rounded-lg bg-critical-50 border border-critical-200 text-[13px] text-critical-700">{error}</div>}
    </Modal>
  );
}
