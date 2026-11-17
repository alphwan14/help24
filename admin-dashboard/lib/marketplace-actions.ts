"use server";

import { revalidatePath } from "next/cache";
import { ApiError, getCurrentAdmin } from "./api";
import { adminActionRequest } from "./arbitration-session";
import { reclassifyInputError, reclassifyRefusalWords, type EmploymentType, type ListingType } from "./listing-type";
import { createServiceClient } from "./supabase-server";

export type RescueSkip = { userId: string; reason: "is_client" | "applied" | "already_notified" | "unavailable" | "daily_limit" | "no_account" };
export type RescueResult = { ok: boolean; error?: string; notified?: number; withPush?: number; skipped?: RescueSkip[] };

/**
 * Tell matching providers about an open request. Any admin; the backend
 * decides, per provider, whether they may be told (RequestRescueService).
 */
export async function notifyProvidersAction(postId: string, providerIds: string[]): Promise<RescueResult> {
  if (providerIds.length === 0) return { ok: false, error: "Choose at least one provider." };
  try {
    const res = await adminActionRequest<{ notified: number; withPush: number; skipped: RescueSkip[] }>(
      `/admin/marketplace/requests/${encodeURIComponent(postId)}/notify-providers`,
      { method: "POST", body: JSON.stringify({ providerIds }) },
    );
    revalidatePath(`/dashboard/marketplace/requests/${postId}`);
    return { ok: true, ...res };
  } catch (err) {
    if (err instanceof ApiError) return { ok: false, error: err.message };
    return { ok: false, error: "Can't reach Help24 right now. Nobody was notified." };
  }
}

export type ReclassifyResult = { ok: boolean; error?: string; applications?: number };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Reclassify a listing posted as the wrong kind (migration 145). Any active
 * admin, with a reason. The admin is confirmed through the backend (/admin/me,
 * the check every admin page relies on); admin_reclassify_post checks the
 * admin again, re-applies the listing rules and the vetting check that
 * service_role would otherwise skip, and records who did it and why.
 *
 * No backend route: the backend is frozen, and this is one guarded database
 * function, the same shape as the partner actions (migration 128).
 */
export async function reclassifyListingAction(
  postId: string,
  currentType: string,
  type: ListingType,
  employmentType: EmploymentType | null,
  reason: string,
): Promise<ReclassifyResult> {
  if (!UUID.test(postId)) return { ok: false, error: "Unknown listing." };
  const invalid = reclassifyInputError({ type, current: currentType, employmentType, reason });
  if (invalid) return { ok: false, error: invalid };
  const admin = await getCurrentAdmin();
  if (!admin) return { ok: false, error: "Your admin session could not be confirmed. Reload and try again." };

  const { data, error } = await createServiceClient().rpc("admin_reclassify_post", {
    p_admin_id: admin.id,
    p_post_id: postId,
    p_type: type,
    p_employment_type: type === "job" ? employmentType : null,
    p_reason: reason.trim(),
  });
  if (error) return { ok: false, error: reclassifyRefusalWords(error.message) };

  revalidatePath(`/dashboard/marketplace/requests/${postId}`);
  for (const list of ["requests", "offers", "jobs"]) revalidatePath(`/dashboard/marketplace/${list}`);
  return { ok: true, applications: (data as { applications?: number } | null)?.applications ?? 0 };
}
