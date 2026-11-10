import "server-only";
import { adminRequest } from "./api";
import type { AlertEmailSettings } from "./alert-email-options";

/** The signed-in admin's own alert email setting (backend /admin/alert-emails, migration 141). */
export function getAlertEmailSettings(): Promise<AlertEmailSettings> {
  return adminRequest<AlertEmailSettings>("/admin/alert-emails");
}
