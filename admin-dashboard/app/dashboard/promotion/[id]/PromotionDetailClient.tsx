"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import type { AdminMe, PromotionAnalytics, PromotionCampaignItem } from "@/lib/api";
import {
  approveCampaign,
  cancelCampaign,
  pauseCampaign,
  rejectCampaign,
  resumeCampaign,
  type ActionResult,
} from "@/lib/promotion-actions";

const STATUS_STYLES: Record<string, string> = {
  active: "bg-green-100 text-green-700",
  pending_review: "bg-blue-100 text-blue-700",
  awaiting_payment: "bg-amber-100 text-amber-700",
  paused: "bg-amber-100 text-amber-700",
  rejected: "bg-red-100 text-red-700",
  completed: "bg-gray-100 text-gray-600",
  expired: "bg-gray-100 text-gray-500",
  cancelled: "bg-gray-100 text-gray-500",
};

function fmtDate(iso: string | null) {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("en-KE", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export default function PromotionDetailClient({
  campaign,
  analytics,
  admin,
}: {
  campaign: PromotionCampaignItem;
  analytics: PromotionAnalytics | null;
  admin: AdminMe;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [rejectReason, setRejectReason] = useState("");
  const [cancelReason, setCancelReason] = useState("");

  // Moderation + oversight writes require senior_admin (mirrors the backend @Roles).
  const canModerate = admin.role === "senior_admin" || admin.role === "super_admin";

  function run(action: () => Promise<ActionResult<PromotionCampaignItem>>, successMsg: string) {
    setError(null);
    setNotice(null);
    startTransition(async () => {
      const result = await action();
      if (result.ok) {
        setNotice(successMsg);
        router.refresh();
      } else {
        setError(result.error ?? "Action failed.");
      }
    });
  }

  const paid = campaign.promotion_payments?.find((p) => p.status === "paid");

  return (
    <div className="space-y-6">
      <Link href="/dashboard/promotion" className="text-sm text-blue-600 hover:underline">
        ← All campaigns
      </Link>

      {/* ── Header card ─────────────────────────────────────────────── */}
      <div className="card p-5 space-y-3">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 className="text-lg font-semibold">
              {campaign.post_title ?? campaign.posts?.title ?? "(deleted listing)"}
            </h2>
            <p className="text-sm text-gray-500">
              {campaign.users?.name ?? campaign.owner_user_id}
              {campaign.users?.email ? ` · ${campaign.users.email}` : ""}
            </p>
          </div>
          <span
            className={`badge ${STATUS_STYLES[campaign.status] ?? "bg-gray-100 text-gray-600"}`}
          >
            {campaign.status.replace(/_/g, " ")}
          </span>
        </div>

        <dl className="grid grid-cols-2 md:grid-cols-4 gap-3 text-sm">
          <div>
            <dt className="text-gray-400 text-xs">Package</dt>
            <dd>
              {campaign.package_name} — KES {campaign.price_kes.toLocaleString("en-KE")} ·{" "}
              {campaign.duration_days}d
            </dd>
          </div>
          <div>
            <dt className="text-gray-400 text-xs">Created</dt>
            <dd>{fmtDate(campaign.created_at)}</dd>
          </div>
          <div>
            <dt className="text-gray-400 text-xs">Window</dt>
            <dd>
              {campaign.starts_at
                ? `${fmtDate(campaign.starts_at)} → ${fmtDate(campaign.ends_at)}`
                : "Not started"}
            </dd>
          </div>
          <div>
            <dt className="text-gray-400 text-xs">Payment</dt>
            <dd>
              {paid
                ? `Paid · ${paid.mpesa_receipt ?? "no receipt"} · KES ${paid.amount_kes.toLocaleString("en-KE")}`
                : "Not paid"}
            </dd>
          </div>
        </dl>

        {campaign.rejection_reason && (
          <p className="text-sm text-red-600">Rejected: {campaign.rejection_reason}</p>
        )}
        {campaign.cancel_reason && (
          <p className="text-sm text-gray-500">Cancelled: {campaign.cancel_reason}</p>
        )}
      </div>

      {(error || notice) && (
        <div
          className={`card p-3 text-sm ${error ? "text-red-700 bg-red-50" : "text-green-700 bg-green-50"}`}
        >
          {error ?? notice}
        </div>
      )}

      {/* ── Moderation ──────────────────────────────────────────────── */}
      {canModerate && campaign.status === "pending_review" && (
        <div className="card p-5 space-y-3">
          <h3 className="font-semibold text-sm">Moderation</h3>
          <p className="text-sm text-gray-500">
            The campaign is paid and awaiting review. Approving starts the{" "}
            {campaign.duration_days}-day serving window immediately.
          </p>
          <div className="flex flex-wrap items-center gap-3">
            <button
              className="btn-primary text-sm"
              disabled={pending}
              onClick={() => run(() => approveCampaign(campaign.id), "Campaign approved — now live.")}
            >
              Approve & go live
            </button>
            <input
              className="input flex-1 min-w-[220px]"
              placeholder="Rejection reason (required to reject)"
              value={rejectReason}
              onChange={(e) => setRejectReason(e.target.value)}
            />
            <button
              className="btn-ghost text-red-600 border border-red-200 hover:bg-red-50"
              disabled={pending || rejectReason.trim().length < 3}
              onClick={() =>
                run(() => rejectCampaign(campaign.id, rejectReason.trim()), "Campaign rejected.")
              }
            >
              Reject
            </button>
          </div>
        </div>
      )}

      {/* ── Oversight ───────────────────────────────────────────────── */}
      {canModerate && (campaign.status === "active" || campaign.status === "paused") && (
        <div className="card p-5 space-y-3">
          <h3 className="font-semibold text-sm">Oversight</h3>
          <div className="flex flex-wrap items-center gap-3">
            {campaign.status === "active" ? (
              <button
                className="btn-ghost border border-gray-200"
                disabled={pending}
                onClick={() => run(() => pauseCampaign(campaign.id), "Campaign paused.")}
              >
                Pause
              </button>
            ) : (
              <button
                className="btn-ghost border border-gray-200"
                disabled={pending}
                onClick={() => run(() => resumeCampaign(campaign.id), "Campaign resumed.")}
              >
                Resume
              </button>
            )}
            <input
              className="input flex-1 min-w-[220px]"
              placeholder="Cancel reason (required to cancel)"
              value={cancelReason}
              onChange={(e) => setCancelReason(e.target.value)}
            />
            <button
              className="btn-ghost text-red-600 border border-red-200 hover:bg-red-50"
              disabled={pending || cancelReason.trim().length < 3}
              onClick={() =>
                run(() => cancelCampaign(campaign.id, cancelReason.trim()), "Campaign cancelled.")
              }
            >
              Cancel campaign
            </button>
          </div>
        </div>
      )}

      {/* ── Performance ─────────────────────────────────────────────── */}
      {analytics && (
        <div className="card p-5 space-y-3">
          <h3 className="font-semibold text-sm">Performance</h3>
          <div className="grid grid-cols-2 md:grid-cols-6 gap-3 text-sm">
            <Stat label="Impressions" value={analytics.totals.impressions} />
            <Stat label="Clicks" value={analytics.totals.clicks} />
            <Stat
              label="CTR"
              value={
                analytics.totals.impressions > 0
                  ? `${(analytics.totals.ctr * 100).toFixed(1)}%`
                  : "—"
              }
            />
            <Stat label="Profile views" value={analytics.totals.profile_views} />
            <Stat label="Phone taps" value={analytics.totals.phone_taps} />
            <Stat label="Messages" value={analytics.totals.messages} />
          </div>
        </div>
      )}

      {/* ── Payment attempts ────────────────────────────────────────── */}
      {campaign.promotion_payments?.length > 0 && (
        <div className="card p-5">
          <h3 className="font-semibold text-sm mb-3">Payment attempts</h3>
          <ul className="space-y-2 text-sm">
            {campaign.promotion_payments.map((p) => (
              <li key={p.id} className="flex flex-wrap justify-between gap-2 border-b border-gray-100 pb-2">
                <span>
                  KES {p.amount_kes.toLocaleString("en-KE")} · {p.phone}
                  {p.mpesa_receipt ? ` · ${p.mpesa_receipt}` : ""}
                  {p.failure_reason ? ` · ${p.failure_reason}` : ""}
                </span>
                <span
                  className={`badge ${
                    p.status === "paid"
                      ? "bg-green-100 text-green-700"
                      : p.status === "failed"
                        ? "bg-red-100 text-red-700"
                        : "bg-amber-100 text-amber-700"
                  }`}
                >
                  {p.status}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}

function Stat({ label, value }: { label: string; value: number | string }) {
  return (
    <div>
      <p className="text-gray-400 text-xs">{label}</p>
      <p className="font-semibold">{typeof value === "number" ? value.toLocaleString("en-KE") : value}</p>
    </div>
  );
}
