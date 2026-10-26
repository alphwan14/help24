"use client";

import { useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Modal from "@/components/moderation/Modal";
import { notifyProvidersAction, type RescueSkip } from "@/lib/marketplace-actions";

export type NotifyCandidate = {
  userId: string;
  name: string;
  tierLabel: string;
  /** Can be sent to now — not applied, not already told, in good standing. */
  eligible: boolean;
  /** Why not, when not eligible. */
  note?: string;
  /** Has a phone registered for push; otherwise it lands in their inbox only. */
  reachable: boolean;
};

const SKIP_WORDS: Record<RescueSkip["reason"], string> = {
  is_client: "is the client",
  applied: "already applied",
  already_notified: "already told about this request",
  unavailable: "suspended or banned",
  daily_limit: "had 3 of these today",
  no_account: "no longer has an account",
};

/**
 * "Notify these providers" for an open request. Nothing is sent until the
 * admin confirms the list; the backend re-checks every person and reports
 * whom it skipped and why.
 */
export default function NotifyProviders({
  postId,
  title,
  location,
  candidates,
  alreadyNotified,
}: {
  postId: string;
  title: string;
  location: string | null;
  candidates: NotifyCandidate[];
  alreadyNotified: number;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [chosen, setChosen] = useState<Set<string>>(() => new Set());
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<string | null>(null);
  const [busy, startTransition] = useTransition();
  const eligible = useMemo(() => candidates.filter((c) => c.eligible), [candidates]);

  function openDialog() {
    setChosen(new Set(eligible.map((c) => c.userId)));
    setError(null);
    setOpen(true);
  }

  function toggle(id: string) {
    const next = new Set(chosen);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    setChosen(next);
  }

  function send() {
    setError(null);
    const ids = [...chosen];
    startTransition(async () => {
      const res = await notifyProvidersAction(postId, ids);
      if (!res.ok) {
        setError(res.error ?? "Nobody was notified.");
        return;
      }
      const n = res.notified ?? 0;
      const push = res.withPush ?? 0;
      const skips = (res.skipped ?? []).map((s) => {
        const who = candidates.find((c) => c.userId === s.userId)?.name ?? "Someone";
        return `${who} ${SKIP_WORDS[s.reason]}`;
      });
      setResult(
        `Told ${n} ${n === 1 ? "provider" : "providers"}` +
          (n ? ` — ${push} by push${n - push ? `, ${n - push} in their app inbox only` : ""}` : "") +
          "." +
          (skips.length ? ` Skipped: ${skips.join("; ")}.` : ""),
      );
      setOpen(false);
      router.refresh();
    });
  }

  const preview = `${title.trim() || "Someone needs help"}${location?.trim() ? ` — ${location.trim()}` : ""}. Open Help24 to send an offer.`;

  return (
    <div className="mt-3 flex flex-wrap items-center gap-3">
      <button type="button" className="btn-primary" disabled={eligible.length === 0} onClick={openDialog}>
        Notify these providers{eligible.length ? ` (${eligible.length})` : ""}
      </button>
      <span className="text-[12px] text-gray-500">
        {alreadyNotified > 0 ? `${alreadyNotified} already told about this request. ` : ""}
        {eligible.length === 0 && "Everyone listed has applied, been told, or can't take work."}
      </span>
      {result && (
        <p role="status" className="w-full p-3 rounded-lg bg-positive-50 border border-positive-200 text-[12.5px] text-positive-700">
          {result}
        </p>
      )}

      <Modal
        open={open}
        title="Tell providers about this request"
        description="Each chosen provider gets one push and an inbox message. Nobody is told twice about the same request, or more than 3 times a day."
        busy={busy}
        onClose={() => setOpen(false)}
        footer={
          <>
            <button type="button" className="btn-ghost" disabled={busy} onClick={() => setOpen(false)}>
              Cancel
            </button>
            <button type="button" className="btn-primary" disabled={busy || chosen.size === 0} onClick={send}>
              {busy ? "Sending…" : `Send to ${chosen.size}`}
            </button>
          </>
        }
      >
        <div>
          <p className="text-xs font-semibold text-gray-600 mb-1">What they will see</p>
          <div className="rounded-xl border border-gray-200 bg-gray-50 px-3.5 py-2.5 text-[13px]">
            <p className="font-semibold text-gray-900">A new request matches your work</p>
            <p className="text-gray-600">{preview}</p>
          </div>
        </div>
        <ul className="divide-y divide-gray-100 max-h-72 overflow-y-auto" data-testid="notify-list">
          {candidates.map((c) => (
            <li key={c.userId} className="py-2">
              <label className={`flex items-start gap-3 ${c.eligible ? "cursor-pointer" : "opacity-60"}`}>
                <input
                  type="checkbox"
                  className="mt-1 h-4 w-4"
                  disabled={!c.eligible}
                  checked={chosen.has(c.userId)}
                  onChange={() => toggle(c.userId)}
                />
                <span className="min-w-0">
                  <span className="text-sm font-medium text-gray-900">{c.name}</span>
                  <span className="ml-2 text-[11.5px] text-gray-500">{c.tierLabel}</span>
                  <span className="block text-[11.5px] text-gray-400">
                    {c.eligible ? (c.reachable ? "Push + inbox" : "No phone registered — inbox only") : c.note}
                  </span>
                </span>
              </label>
            </li>
          ))}
        </ul>
        {error && (
          <p role="alert" className="p-3 rounded-lg bg-critical-50 border border-critical-200 text-[12.5px] text-critical-700">
            {error}
          </p>
        )}
      </Modal>
    </div>
  );
}
