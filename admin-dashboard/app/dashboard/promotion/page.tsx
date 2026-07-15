import Link from "next/link";
import DataTable from "@/components/DataTable";
import RestoringAccess from "../disputes/RestoringAccess";
import {
  getCurrentAdmin,
  getPromotionCampaigns,
  type PromotionCampaignItem,
} from "@/lib/api";

// Live operational data — always render fresh.
export const dynamic = "force-dynamic";

const FILTERS = [
  "pending_review",
  "active",
  "paused",
  "awaiting_payment",
  "completed",
  "rejected",
] as const;

const STATUS_STYLES: Record<string, string> = {
  active: "bg-green-100 text-green-700",
  pending_review: "bg-blue-100 text-blue-700",
  awaiting_payment: "bg-amber-100 text-amber-700",
  paused: "bg-amber-100 text-amber-700",
  rejected: "bg-red-100 text-red-700",
  completed: "bg-gray-100 text-gray-600",
  expired: "bg-gray-100 text-gray-500",
  cancelled: "bg-gray-100 text-gray-500",
  draft: "bg-gray-100 text-gray-500",
};

function fmtDate(iso: string | null) {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString("en-KE", {
    day: "2-digit",
    month: "short",
    year: "numeric",
  });
}

type PageProps = { searchParams: Promise<{ status?: string }> };

export default async function PromotionCampaignsPage({ searchParams }: PageProps) {
  const admin = await getCurrentAdmin();
  if (!admin) return <RestoringAccess />;

  const { status } = await searchParams;
  const active =
    status && FILTERS.includes(status as (typeof FILTERS)[number]) ? status : undefined;
  const campaigns = await getPromotionCampaigns(active);

  const columns = [
    {
      key: "campaign",
      label: "Campaign",
      render: (r: PromotionCampaignItem) => (
        <div>
          <Link
            href={`/dashboard/promotion/${r.id}`}
            className="font-medium text-sm text-blue-600 hover:underline"
          >
            {r.post_title ?? r.posts?.title ?? "(deleted listing)"}
          </Link>
          <p className="text-xs text-gray-400 mt-0.5">
            {r.users?.name ?? r.owner_user_id} · {fmtDate(r.created_at)}
          </p>
        </div>
      ),
    },
    {
      key: "package",
      label: "Package",
      render: (r: PromotionCampaignItem) => (
        <div>
          <span className="text-sm text-gray-700">{r.package_name}</span>
          <p className="text-xs text-gray-400">
            KES {r.price_kes.toLocaleString("en-KE")} · {r.duration_days}d
          </p>
        </div>
      ),
    },
    {
      key: "status",
      label: "Status",
      render: (r: PromotionCampaignItem) => (
        <span className={`badge ${STATUS_STYLES[r.status] ?? "bg-gray-100 text-gray-600"}`}>
          {r.status.replace(/_/g, " ")}
        </span>
      ),
    },
    {
      key: "window",
      label: "Window",
      render: (r: PromotionCampaignItem) =>
        r.starts_at ? (
          <span className="text-xs text-gray-600">
            {fmtDate(r.starts_at)} → {fmtDate(r.ends_at)}
            {r.status === "active" ? ` (${r.days_remaining}d left)` : ""}
          </span>
        ) : (
          <span className="text-xs text-gray-400">—</span>
        ),
    },
    {
      key: "payment",
      label: "Payment",
      render: (r: PromotionCampaignItem) => {
        const paid = r.promotion_payments?.find((p) => p.status === "paid");
        return paid ? (
          <span className="text-xs text-green-700">
            Paid{paid.mpesa_receipt ? ` · ${paid.mpesa_receipt}` : ""}
          </span>
        ) : (
          <span className="text-xs text-gray-400">Unpaid</span>
        );
      },
    },
  ];

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <Link
          href="/dashboard/promotion"
          className={`badge ${!active ? "bg-gray-900 text-white" : "bg-gray-100 text-gray-600"}`}
        >
          All
        </Link>
        {FILTERS.map((f) => (
          <Link
            key={f}
            href={`/dashboard/promotion?status=${f}`}
            className={`badge ${active === f ? "bg-gray-900 text-white" : "bg-gray-100 text-gray-600"}`}
          >
            {f.replace(/_/g, " ")}
          </Link>
        ))}
        <span className="flex-1" />
        <Link href="/dashboard/promotion/packages" className="text-sm text-blue-600 hover:underline">
          Packages
        </Link>
        <Link href="/dashboard/promotion/revenue" className="text-sm text-blue-600 hover:underline">
          Revenue
        </Link>
      </div>
      <DataTable columns={columns} rows={campaigns} emptyMessage="No campaigns found." />
    </div>
  );
}
