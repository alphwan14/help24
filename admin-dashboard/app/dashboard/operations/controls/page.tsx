import { getAppConfig, getCurrentAdmin, startEarly } from "@/lib/api";
import { CONTROL_KEYS, type ControlKey, type VersionUsage } from "@/lib/app-controls";
import { getLatestRelease } from "@/lib/latest-release";
import { createServiceClient } from "@/lib/supabase-server";
import RefreshWhenConnected from "@/components/RefreshWhenConnected";
import ControlsClient, { type HistoryEntry } from "./ControlsClient";

// Per-admin (canEdit) and must show the value phones receive NOW.
export const dynamic = "force-dynamic";

async function getHistory(): Promise<{ rows: HistoryEntry[]; available: boolean }> {
  const { data, error } = await createServiceClient()
    .from("app_settings_history")
    .select("id, key, previous_value, new_value, reason, admin_email, admin_role, created_at")
    .order("created_at", { ascending: false })
    .limit(40);
  if (error) {
    // 42P01 / PGRST205: migration 125 not applied yet. Anything else is a
    // failed read — both mean "no history to show", said differently.
    console.error("[controls] history read failed:", error.code, error.message);
    return { rows: [], available: false };
  }
  return { rows: (data ?? []) as HistoryEntry[], available: true };
}

async function getUpdatedAt(): Promise<Partial<Record<ControlKey, string>>> {
  const { data, error } = await createServiceClient().from("app_settings").select("key, updated_at").in("key", CONTROL_KEYS);
  if (error) return {};
  return Object.fromEntries((data ?? []).map((r) => [r.key, r.updated_at]));
}

const USAGE_WINDOW_DAYS = 30;

/**
 * Versions reported by members active in the last 30 days (migration 126,
 * app 1.0.6+). null when the column is not there yet — the page then says
 * versions are not being collected, rather than showing everyone as unknown.
 */
async function getVersionUsage(): Promise<VersionUsage | null> {
  const since = new Date(Date.now() - USAGE_WINDOW_DAYS * 86400_000).toISOString();
  const { data, error } = await createServiceClient()
    .from("users")
    .select("app_version")
    .or(`last_seen.gte."${since}",last_login.gte."${since}"`)
    .limit(100000);
  if (error) {
    console.error("[controls] version usage unavailable:", error.code, error.message);
    return null;
  }
  const counts = new Map<string, number>();
  let unreported = 0;
  for (const r of data ?? []) {
    const v = (r as { app_version: string | null }).app_version;
    if (v) counts.set(v, (counts.get(v) ?? 0) + 1);
    else unreported++;
  }
  const versions = [...counts].map(([version, count]) => ({ version, count }));
  versions.sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }));
  return { versions, unreported, windowDays: USAGE_WINDOW_DAYS };
}

export default async function AppControlsPage() {
  const configRequest = startEarly(getAppConfig());
  const historyRequest = startEarly(getHistory());
  const updatedRequest = startEarly(getUpdatedAt());
  const releaseRequest = getLatestRelease(); // never throws
  const usageRequest = getVersionUsage(); // never throws

  const admin = await getCurrentAdmin();
  const [config, history, updatedAt, latest, usage] = await Promise.all([
    configRequest.catch(() => null),
    historyRequest,
    updatedRequest,
    releaseRequest,
    usageRequest,
  ]);

  if (!admin || !config) {
    return (
      <p className="card p-4 text-sm text-gray-500">
        The app&apos;s controls could not be read just now, so nothing can be changed. Reload to try again.
        <RefreshWhenConnected />
      </p>
    );
  }

  return (
    <ControlsClient
      config={config.config}
      canEdit={admin.role === "senior_admin" || admin.role === "super_admin"}
      latest={latest}
      history={history.rows}
      historyAvailable={history.available}
      updatedAt={updatedAt}
      usage={usage}
    />
  );
}
