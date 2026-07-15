import { notFound, redirect } from "next/navigation";
import {
  ApiError,
  getCurrentAdmin,
  getPromotionAnalytics,
  getPromotionCampaign,
  type PromotionAnalytics,
  type PromotionCampaignItem,
} from "@/lib/api";
import PromotionDetailClient from "./PromotionDetailClient";

export const dynamic = "force-dynamic";

export default async function PromotionDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const admin = await getCurrentAdmin();
  if (!admin) redirect("/dashboard/promotion");

  let campaign: PromotionCampaignItem;
  try {
    campaign = await getPromotionCampaign(id);
  } catch (err) {
    if (err instanceof ApiError && (err.status === 404 || err.status === 400)) notFound();
    throw err;
  }

  let analytics: PromotionAnalytics | null = null;
  try {
    analytics = await getPromotionAnalytics(id);
  } catch {
    // analytics are secondary — the moderation view must still render
  }

  return <PromotionDetailClient campaign={campaign} analytics={analytics} admin={admin} />;
}
