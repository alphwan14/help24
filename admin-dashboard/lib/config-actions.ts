"use server";

import { revalidatePath } from "next/cache";
import { ApiError } from "./api";
import { adminActionRequest } from "./arbitration-session";
import { CONTROL_KEYS, controlProblems, type ControlKey } from "./app-controls";
import { getLatestRelease } from "./latest-release";

export type ControlResult = { ok: boolean; error?: string; recorded?: boolean };

/**
 * Change one of the app's live controls. senior_admin (the backend checks, and
 * the database checks again). The reason and the admin are recorded with the
 * change, in the same transaction (migration 125).
 */
export async function saveAppControlAction(
  key: ControlKey,
  value: Record<string, unknown>,
  reason: string,
): Promise<ControlResult> {
  if (!CONTROL_KEYS.includes(key)) return { ok: false, error: "Unknown control." };
  if (reason.trim().length < 5) return { ok: false, error: "Say why — at least 5 characters." };
  // Re-checked here, not only in the browser: the release list is read fresh.
  const problems = controlProblems(key, value, (await getLatestRelease())?.version ?? null);
  if (problems.length) return { ok: false, error: problems[0] };
  try {
    const res = await adminActionRequest<{ recorded?: boolean }>(`/admin/config/${encodeURIComponent(key)}`, {
      method: "PATCH",
      body: JSON.stringify({ value, reason: reason.trim() }),
    });
    revalidatePath("/dashboard/operations/controls");
    return { ok: true, recorded: res.recorded !== false };
  } catch (err) {
    if (err instanceof ApiError) {
      if (err.status === 403) return { ok: false, error: "Changing app controls needs a Senior Admin." };
      return { ok: false, error: err.message };
    }
    return { ok: false, error: "Could not reach the backend. Nothing was changed." };
  }
}
