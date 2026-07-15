"use server";

import { revalidatePath } from "next/cache";
import { ApiError, adminRequest, type PromotionCampaignItem, type PromotionPackageItem } from "./api";

/**
 * Server Actions for Business Promotion WRITES (disputes-actions pattern):
 * every write goes through the RBAC-protected NestJS API with the httpOnly
 * bearer token; results are structured { ok, error? } so client components
 * render errors inline; revalidatePath refreshes the server components.
 */

export type ActionResult<T = undefined> = {
  ok: boolean;
  error?: string;
  data?: T;
};

function toResult<T = undefined>(err: unknown): ActionResult<T> {
  if (err instanceof ApiError) return { ok: false, error: err.message };
  return { ok: false, error: "Unexpected error. Please try again." };
}

function revalidateCampaign(id: string) {
  revalidatePath(`/dashboard/promotion/${id}`);
  revalidatePath("/dashboard/promotion");
}

export async function approveCampaign(id: string): Promise<ActionResult<PromotionCampaignItem>> {
  try {
    const data = await adminRequest<PromotionCampaignItem>(
      `/admin/promotions/campaigns/${id}/approve`,
      { method: "POST" },
    );
    revalidateCampaign(id);
    return { ok: true, data };
  } catch (err) {
    return toResult(err);
  }
}

export async function rejectCampaign(
  id: string,
  reason: string,
): Promise<ActionResult<PromotionCampaignItem>> {
  try {
    const data = await adminRequest<PromotionCampaignItem>(
      `/admin/promotions/campaigns/${id}/reject`,
      { method: "POST", body: JSON.stringify({ reason }) },
    );
    revalidateCampaign(id);
    return { ok: true, data };
  } catch (err) {
    return toResult(err);
  }
}

export async function pauseCampaign(id: string): Promise<ActionResult<PromotionCampaignItem>> {
  try {
    const data = await adminRequest<PromotionCampaignItem>(
      `/admin/promotions/campaigns/${id}/pause`,
      { method: "POST" },
    );
    revalidateCampaign(id);
    return { ok: true, data };
  } catch (err) {
    return toResult(err);
  }
}

export async function resumeCampaign(id: string): Promise<ActionResult<PromotionCampaignItem>> {
  try {
    const data = await adminRequest<PromotionCampaignItem>(
      `/admin/promotions/campaigns/${id}/resume`,
      { method: "POST" },
    );
    revalidateCampaign(id);
    return { ok: true, data };
  } catch (err) {
    return toResult(err);
  }
}

export async function cancelCampaign(
  id: string,
  reason: string,
): Promise<ActionResult<PromotionCampaignItem>> {
  try {
    const data = await adminRequest<PromotionCampaignItem>(
      `/admin/promotions/campaigns/${id}/cancel`,
      { method: "POST", body: JSON.stringify({ reason }) },
    );
    revalidateCampaign(id);
    return { ok: true, data };
  } catch (err) {
    return toResult(err);
  }
}

export async function updatePackage(
  id: string,
  patch: Partial<Pick<PromotionPackageItem, "name" | "description" | "price_kes" | "duration_days" | "active">>,
): Promise<ActionResult<PromotionPackageItem>> {
  try {
    const data = await adminRequest<PromotionPackageItem>(
      `/admin/promotions/packages/${id}`,
      { method: "PATCH", body: JSON.stringify(patch) },
    );
    revalidatePath("/dashboard/promotion/packages");
    return { ok: true, data };
  } catch (err) {
    return toResult(err);
  }
}
