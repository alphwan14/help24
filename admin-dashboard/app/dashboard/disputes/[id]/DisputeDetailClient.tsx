"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";

type DisputeDetail = {
  id: string;
  status: string;
  reason: string;
  admin_notes: string | null;
  resolved_by: string | null;
  provider_amount: number | null;
  buyer_refund: number | null;
  created_at: string;
  resolved_at: string | null;
  posts: {
    id: string;
    title: string;
    price: number;
    author_user_id: string;
    selected_provider_id: string;
    status: string;
  } | null;
  transactions: {
    id: string;
    amount: number;
    fee: number;
    total_paid: number;
    status: string;
    mpesa_receipt: string | null;
    created_at: string;
  } | null;
  job_completions: {
    id: string;
    status: string;
    provider_note: string | null;
    created_at: string;
  } | null;
  buyer: { id: string; name: string | null; phone_number: string | null } | null;
  provider: { id: string; name: string | null; phone_number: string | null } | null;
};

const STATUS_STYLES: Record<string, string> = {
  open: "bg-red-100 text-red-700",
  under_review: "bg-orange-100 text-orange-700",
  resolved_release: "bg-green-100 text-green-700",
  resolved_refund: "bg-blue-100 text-blue-700",
  resolved_partial: "bg-purple-100 text-purple-700",
};

function fmtDate(iso: string) {
  return new Date(iso).toLocaleString("en-KE", {
    day: "2-digit", month: "short", year: "numeric",
    hour: "2-digit", minute: "2-digit",
  });
}

function fmtKES(n: number) {
  return `KES ${n.toLocaleString("en-KE")}`;
}

const BACKEND = process.env.NEXT_PUBLIC_BACKEND_URL ?? "https://help24-backend.onrender.com";

export default function DisputeDetailClient({ dispute }: { dispute: DisputeDetail }) {
  const router = useRouter();
  const isResolved = ["resolved_release", "resolved_refund", "resolved_partial"].includes(
    dispute.status
  );

  const [action, setAction] = useState<"release_full" | "refund_full" | "partial_split">(
    "release_full"
  );
  const [providerAmount, setProviderAmount] = useState("");
  const [buyerRefund, setBuyerRefund] = useState("");
  const [adminNotes, setAdminNotes] = useState("");
  const [resolvedBy, setResolvedBy] = useState("");
  const [resolving, setResolving] = useState(false);
  const [resolveError, setResolveError] = useState<string | null>(null);
  const [resolveSuccess, setResolveSuccess] = useState(false);

  const tx = dispute.transactions;
  const post = dispute.posts;

  async function handleResolve(e: React.FormEvent) {
    e.preventDefault();
    if (!resolvedBy.trim()) {
      setResolveError("Please enter your name or admin ID.");
      return;
    }
    if (action === "partial_split" && (!providerAmount || !buyerRefund)) {
      setResolveError("Enter both provider amount and buyer refund for partial split.");
      return;
    }

    setResolving(true);
    setResolveError(null);

    try {
      const body: Record<string, unknown> = {
        dispute_id: dispute.id,
        action,
        resolved_by: resolvedBy.trim(),
        admin_notes: adminNotes.trim() || undefined,
      };
      if (action === "partial_split") {
        body.provider_amount = parseInt(providerAmount, 10);
        body.buyer_refund = parseInt(buyerRefund, 10);
      }

      const res = await fetch(`${BACKEND}/admin/disputes/resolve`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });

      const json = (await res.json()) as { message?: string };
      if (!res.ok) {
        const msg = Array.isArray(json.message)
          ? (json.message as string[]).join("; ")
          : (json.message ?? "Failed to resolve dispute.");
        setResolveError(msg);
      } else {
        setResolveSuccess(true);
        setTimeout(() => router.push("/dashboard/disputes"), 2000);
      }
    } catch {
      setResolveError("Network error. Please try again.");
    } finally {
      setResolving(false);
    }
  }

  return (
    <div className="space-y-6 max-w-3xl">
      {/* Header */}
      <div className="card p-5">
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="font-mono text-xs text-gray-400 mb-1">{dispute.id}</p>
            <h2 className="text-lg font-bold text-gray-900">{post?.title ?? "Unknown Job"}</h2>
            <p className="text-sm text-gray-500 mt-1">{fmtDate(dispute.created_at)}</p>
          </div>
          <span className={`badge shrink-0 ${STATUS_STYLES[dispute.status] ?? "bg-gray-100 text-gray-600"}`}>
            {dispute.status.replace(/_/g, " ")}
          </span>
        </div>
      </div>

      {/* Parties */}
      <div className="grid grid-cols-2 gap-4">
        <div className="card p-4">
          <p className="text-xs font-semibold text-gray-400 mb-2 uppercase tracking-wide">Client (Buyer)</p>
          <p className="font-semibold text-gray-800">{dispute.buyer?.name ?? "—"}</p>
          <p className="text-sm text-gray-500">{dispute.buyer?.phone_number ?? "—"}</p>
          <p className="text-xs text-gray-400 mt-1 font-mono">{post?.author_user_id?.slice(0, 16)}…</p>
        </div>
        <div className="card p-4">
          <p className="text-xs font-semibold text-gray-400 mb-2 uppercase tracking-wide">Provider</p>
          <p className="font-semibold text-gray-800">{dispute.provider?.name ?? "—"}</p>
          <p className="text-sm text-gray-500">{dispute.provider?.phone_number ?? "—"}</p>
          <p className="text-xs text-gray-400 mt-1 font-mono">{post?.selected_provider_id?.slice(0, 16)}…</p>
        </div>
      </div>

      {/* Transaction */}
      {tx && (
        <div className="card p-4">
          <p className="text-xs font-semibold text-gray-400 mb-3 uppercase tracking-wide">Payment Details</p>
          <div className="grid grid-cols-3 gap-3 text-sm">
            <div>
              <p className="text-gray-400 text-xs">Service Amount</p>
              <p className="font-bold text-gray-900">{fmtKES(tx.amount)}</p>
            </div>
            <div>
              <p className="text-gray-400 text-xs">Platform Fee</p>
              <p className="font-semibold text-gray-700">{fmtKES(tx.fee)}</p>
            </div>
            <div>
              <p className="text-gray-400 text-xs">Total Paid</p>
              <p className="font-semibold text-gray-700">{fmtKES(tx.total_paid)}</p>
            </div>
          </div>
          {tx.mpesa_receipt && (
            <p className="text-xs text-gray-400 mt-3">
              M-Pesa Receipt: <span className="font-mono">{tx.mpesa_receipt}</span>
            </p>
          )}
        </div>
      )}

      {/* Dispute reason */}
      <div className="card p-4">
        <p className="text-xs font-semibold text-gray-400 mb-2 uppercase tracking-wide">Dispute Reason</p>
        <p className="text-gray-800 text-sm leading-relaxed">{dispute.reason}</p>
      </div>

      {/* Provider completion note */}
      {dispute.job_completions?.provider_note && (
        <div className="card p-4">
          <p className="text-xs font-semibold text-gray-400 mb-2 uppercase tracking-wide">
            Provider Completion Note
          </p>
          <p className="text-gray-800 text-sm leading-relaxed">{dispute.job_completions.provider_note}</p>
        </div>
      )}

      {/* Resolution summary (already resolved) */}
      {isResolved && (
        <div className="card p-4 border border-green-200 bg-green-50">
          <p className="text-xs font-semibold text-green-700 mb-2 uppercase tracking-wide">Resolution</p>
          <p className="text-sm font-semibold text-green-800">{dispute.status.replace(/_/g, " ")}</p>
          {dispute.admin_notes && (
            <p className="text-sm text-green-700 mt-1">{dispute.admin_notes}</p>
          )}
          {dispute.resolved_by && (
            <p className="text-xs text-green-600 mt-1">Resolved by: {dispute.resolved_by}</p>
          )}
          {dispute.resolved_at && (
            <p className="text-xs text-green-500 mt-1">{fmtDate(dispute.resolved_at)}</p>
          )}
          {dispute.provider_amount != null && (
            <p className="text-sm mt-2 text-green-700">
              Provider payout: <strong>{fmtKES(dispute.provider_amount)}</strong> · Buyer refund:{" "}
              <strong>{fmtKES(dispute.buyer_refund ?? 0)}</strong>
            </p>
          )}
        </div>
      )}

      {/* Admin resolution form */}
      {!isResolved && !resolveSuccess && (
        <form onSubmit={handleResolve} className="card p-5 space-y-4">
          <p className="text-sm font-bold text-gray-900">Admin Resolution</p>

          {/* Action selector */}
          <div>
            <label className="text-xs font-semibold text-gray-500 block mb-2">Action</label>
            <div className="grid grid-cols-3 gap-2">
              {(["release_full", "refund_full", "partial_split"] as const).map((a) => (
                <button
                  key={a}
                  type="button"
                  onClick={() => setAction(a)}
                  className={`py-2.5 px-3 rounded-lg text-xs font-semibold border transition-all ${
                    action === a
                      ? a === "release_full"
                        ? "bg-green-600 text-white border-green-600"
                        : a === "refund_full"
                        ? "bg-blue-600 text-white border-blue-600"
                        : "bg-purple-600 text-white border-purple-600"
                      : "bg-white text-gray-600 border-gray-200 hover:border-gray-400"
                  }`}
                >
                  {a === "release_full"
                    ? "Release to Provider"
                    : a === "refund_full"
                    ? "Refund Buyer"
                    : "Partial Split"}
                </button>
              ))}
            </div>
            <p className="text-xs text-gray-400 mt-2">
              {action === "release_full" &&
                "Full payment released to provider via M-Pesa B2C payout."}
              {action === "refund_full" &&
                "Full refund to buyer — marked as processed. Admin transfers M-Pesa externally."}
              {action === "partial_split" &&
                "Split between provider and buyer — admin processes both M-Pesa transfers manually."}
            </p>
          </div>

          {/* Partial split amounts */}
          {action === "partial_split" && (
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="text-xs font-semibold text-gray-500 block mb-1">
                  Provider Amount (KES)
                </label>
                <input
                  type="number"
                  min={0}
                  value={providerAmount}
                  onChange={(e) => setProviderAmount(e.target.value)}
                  className="input w-full"
                  placeholder={tx ? String(Math.floor(tx.amount / 2)) : "e.g. 1500"}
                  required
                />
              </div>
              <div>
                <label className="text-xs font-semibold text-gray-500 block mb-1">
                  Buyer Refund (KES)
                </label>
                <input
                  type="number"
                  min={0}
                  value={buyerRefund}
                  onChange={(e) => setBuyerRefund(e.target.value)}
                  className="input w-full"
                  placeholder={tx ? String(Math.ceil(tx.amount / 2)) : "e.g. 500"}
                  required
                />
              </div>
            </div>
          )}

          {/* Admin notes */}
          <div>
            <label className="text-xs font-semibold text-gray-500 block mb-1">
              Admin Notes <span className="text-gray-300">(optional)</span>
            </label>
            <textarea
              value={adminNotes}
              onChange={(e) => setAdminNotes(e.target.value)}
              rows={3}
              className="input w-full resize-none"
              placeholder="Explain your decision. This is sent to both parties in their notifications."
            />
          </div>

          {/* Resolved by */}
          <div>
            <label className="text-xs font-semibold text-gray-500 block mb-1">
              Your Name / Admin ID <span className="text-red-500">*</span>
            </label>
            <input
              type="text"
              value={resolvedBy}
              onChange={(e) => setResolvedBy(e.target.value)}
              className="input w-full"
              placeholder="e.g. Lawrence — Admin"
              required
            />
          </div>

          {resolveError && (
            <div className="p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-600">
              {resolveError}
            </div>
          )}

          <button
            type="submit"
            disabled={resolving}
            className={`w-full py-3 rounded-xl font-semibold text-white text-sm transition-all disabled:opacity-50 ${
              action === "release_full"
                ? "bg-green-600 hover:bg-green-700"
                : action === "refund_full"
                ? "bg-blue-600 hover:bg-blue-700"
                : "bg-purple-600 hover:bg-purple-700"
            }`}
          >
            {resolving
              ? "Processing…"
              : `Confirm: ${action.replace(/_/g, " ")}`}
          </button>
        </form>
      )}

      {resolveSuccess && (
        <div className="card p-6 text-center border border-green-200 bg-green-50">
          <p className="text-green-700 font-bold text-lg">✓ Dispute Resolved</p>
          <p className="text-green-600 text-sm mt-1">Redirecting to disputes list…</p>
        </div>
      )}
    </div>
  );
}
