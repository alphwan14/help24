"use server";

import { revalidatePath } from "next/cache";
import { ApiError } from "./api";
import { adminActionRequest } from "./arbitration-session";

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
    return { ok: false, error: "Could not reach the backend. Nobody was notified." };
  }
}
