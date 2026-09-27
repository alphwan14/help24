"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { reconcilePayoutAction } from "@/lib/payout-actions";

/**
 * "Check with M-Pesa" for a payout stuck in payout_pending. Two taps — the
 * second confirms — because it contacts the payment provider, even though it
 * can only ever settle on a confirmed result.
 */
export default function ReconcileButton({ postId }: { postId: string }) {
  const router = useRouter();
  const [confirming, setConfirming] = useState(false);
  const [result, setResult] = useState<{ ok: boolean; message: string } | null>(null);
  const [pending, start] = useTransition();

  if (result) {
    return (
      <p className={`text-[11.5px] max-w-[220px] whitespace-normal ${result.ok ? "text-positive-700" : "text-critical-700"}`}>
        {result.message}
      </p>
    );
  }

  if (!confirming) {
    return (
      <button
        type="button"
        onClick={() => setConfirming(true)}
        className="px-2.5 py-1 rounded-md border border-gray-200 text-[12px] font-semibold text-gray-700 hover:bg-gray-50"
      >
        Check with M-Pesa
      </button>
    );
  }

  return (
    <div className="flex items-center gap-1.5">
      <button
        type="button"
        disabled={pending}
        onClick={() =>
          start(async () => {
            const r = await reconcilePayoutAction(postId);
            setResult(r);
            if (r.ok) router.refresh();
          })
        }
        className="px-2.5 py-1 rounded-md bg-brand-600 text-on-action text-[12px] font-semibold disabled:opacity-50"
      >
        {pending ? "Asking…" : "Ask for the result"}
      </button>
      <button type="button" disabled={pending} onClick={() => setConfirming(false)} className="text-[12px] text-gray-500 hover:text-gray-800">
        Cancel
      </button>
    </div>
  );
}
