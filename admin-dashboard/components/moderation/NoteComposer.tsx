"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { addReportNoteAction, addUserNoteAction } from "@/lib/moderation-actions";

/**
 * Internal notes: context for the next admin. Appended to the audit ledger
 * like every other action — a note can be added, never edited or deleted.
 */
export default function NoteComposer({ reportId, userId }: { reportId?: string; userId?: string }) {
  const router = useRouter();
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  function submit() {
    setError(null);
    start(async () => {
      const res = reportId ? await addReportNoteAction(reportId, note) : await addUserNoteAction(userId!, note);
      if (!res.ok) {
        setError(res.error ?? "The note was not saved.");
        return;
      }
      setNote("");
      router.refresh();
    });
  }

  return (
    <div className="space-y-2">
      <textarea
        className="input resize-none text-[13px]"
        rows={3}
        maxLength={4000}
        placeholder="Add an internal note — admins only. Notes are permanent."
        value={note}
        onChange={(e) => setNote(e.target.value)}
        aria-label="Internal note"
      />
      <div className="flex items-center justify-between gap-2">
        <span className="text-[11px] text-gray-400">Never shown to the account holder or the reporter.</span>
        <button type="button" className="btn-primary !min-h-[34px] !py-1.5 text-[12.5px]" disabled={!note.trim() || pending} onClick={submit}>
          {pending ? "Saving…" : "Add note"}
        </button>
      </div>
      {error && <p className="text-[12.5px] text-critical-700">{error}</p>}
    </div>
  );
}
