"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import ReasonDialog from "@/components/moderation/ReasonDialog";
import { reviewVerificationAction } from "@/lib/verifications-actions";

/**
 * Approve or reject one submission. Approving is one deliberate extra click
 * (it opens work with children or in people's homes); rejecting needs a
 * reason, which the provider receives word for word.
 */
export default function ReviewPanel({
  id,
  kind,
  documentType,
  approveBlockedReason,
  reasons,
}: {
  id: string;
  kind: "id" | "care";
  documentType: string;
  /** Set when approval would be refused (e.g. a Care check before the ID). */
  approveBlockedReason?: string | null;
  reasons: string[];
}) {
  const router = useRouter();
  const [confirming, setConfirming] = useState(false);
  const [rejectOpen, setRejectOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  const approveEffect =
    kind === "id"
      ? "The profile shows “ID verified”, and they can offer and apply for tutoring, driving, security and house-cleaning work."
      : documentType === "receipt"
        ? "Their care listings go live marked “Certificate pending” for 30 days. They still cannot apply for care jobs or be hired until a certificate is approved."
        : "The profile shows “Care checked”, and they can offer, apply for and be hired for care work.";

  function approve() {
    setError(null);
    start(async () => {
      const r = await reviewVerificationAction(id, "approve");
      if (!r.ok) {
        setError(r.error ?? "Could not record the decision.");
        setConfirming(false);
        return;
      }
      router.refresh();
    });
  }

  return (
    <div className="card p-4 space-y-3">
      <h3 className="text-[13px] font-semibold text-gray-900">Decision</h3>
      <p className="text-[12.5px] text-gray-600">{approveEffect}</p>

      {approveBlockedReason && (
        <p className="text-[12.5px] rounded-lg border border-caution-200 bg-caution-50 text-caution-800 px-3 py-2">
          {approveBlockedReason}
        </p>
      )}

      {error && (
        <p role="alert" className="text-[12.5px] rounded-lg border border-critical-200 bg-critical-50 text-critical-700 px-3 py-2">
          {error}
        </p>
      )}

      <div className="flex flex-col gap-2">
        {!confirming ? (
          <button
            type="button"
            disabled={pending || !!approveBlockedReason}
            onClick={() => setConfirming(true)}
            className="inline-flex items-center justify-center rounded-lg bg-gray-900 text-on-action font-semibold min-h-[38px] px-3 text-[13px] disabled:opacity-50"
          >
            Approve…
          </button>
        ) : (
          <div className="rounded-lg border border-gray-200 p-3 space-y-2">
            <p className="text-[12.5px] text-gray-700">
              Confirm the name matches the profile, the document is valid, and the selfie shows the same face holding it.
            </p>
            <div className="flex gap-2">
              <button
                type="button"
                disabled={pending}
                onClick={approve}
                className="flex-1 inline-flex items-center justify-center rounded-lg bg-positive-600 text-on-action font-semibold min-h-[36px] px-3 text-[12.5px] disabled:opacity-50"
              >
                {pending ? "Recording…" : "Confirm approval"}
              </button>
              <button
                type="button"
                disabled={pending}
                onClick={() => setConfirming(false)}
                className="inline-flex items-center justify-center rounded-lg border border-gray-200 text-gray-700 font-semibold min-h-[36px] px-3 text-[12.5px]"
              >
                Cancel
              </button>
            </div>
          </div>
        )}

        <button
          type="button"
          disabled={pending}
          onClick={() => setRejectOpen(true)}
          className="inline-flex items-center justify-center rounded-lg border border-critical-200 text-critical-700 hover:bg-critical-50 font-semibold min-h-[38px] px-3 text-[13px] disabled:opacity-50"
        >
          Reject…
        </button>
      </div>

      <ReasonDialog
        open={rejectOpen}
        onClose={() => setRejectOpen(false)}
        title="Reject this submission"
        description="The provider receives this reason word for word, so say what to fix. They can send new photos straight away."
        reasonLabel="Reason sent to the provider"
        reasonHint="Also recorded with your name."
        suggestions={reasons}
        withNote={false}
        danger
        confirmLabel="Reject"
        onConfirm={(reason) => reviewVerificationAction(id, "reject", reason)}
      />
    </div>
  );
}
