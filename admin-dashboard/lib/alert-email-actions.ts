"use server";

import { revalidatePath } from "next/cache";
import { ApiError } from "./api";
import { adminActionRequest } from "./arbitration-session";
import type { AlertEmailCategory, AlertEmailFrequency, AlertEmailSettings } from "./alert-email-options";

/** Writes for the admin's own alert email setting. Each returns a result instead of throwing. */

export type AlertEmailResult = { ok: boolean; error?: string; settings?: AlertEmailSettings; sentTo?: string };

function fail(err: unknown): AlertEmailResult {
  if (err instanceof ApiError) return { ok: false, error: err.message };
  return { ok: false, error: "Unexpected error. Please try again." };
}

export async function saveAlertEmailSettings(
  frequency: AlertEmailFrequency,
  categories: AlertEmailCategory[],
): Promise<AlertEmailResult> {
  try {
    const settings = await adminActionRequest<AlertEmailSettings>("/admin/alert-emails", {
      method: "PUT",
      body: JSON.stringify({ frequency, categories }),
    });
    revalidatePath("/dashboard/settings");
    return { ok: true, settings };
  } catch (err) {
    return fail(err);
  }
}

export async function sendTestAlertEmail(): Promise<AlertEmailResult> {
  try {
    const r = await adminActionRequest<{ sent: true; to: string }>("/admin/alert-emails/test", { method: "POST" });
    return { ok: true, sentTo: r.to };
  } catch (err) {
    return fail(err);
  }
}
