/**
 * The app's live controls — what `GET /admin/config` serves and what the App
 * controls page edits. The shapes mirror backend/src/app-config/client-config.ts
 * (the contract the Flutter app compiles a copy of), so a field here that is
 * not there would be dropped by the backend's merge.
 *
 * Pure: no fetches, no React. The page, the server action and the tests share
 * it, so the words an admin confirms are the words that describe the change.
 */

export type KillSwitches = { payments: boolean; promotions: boolean; posting: boolean; applications: boolean };
export type Maintenance = { active: boolean; message: string };
export type MinVersion = { soft: string; hard: string; message: string; store_url: string };
export type Announcement = { id: string; active: boolean; message: string; url: string };

export type ClientConfig = {
  ops: { kill_switches: KillSwitches; maintenance: Maintenance; min_version: MinVersion; announcement: Announcement };
  tuning: { payments: { poll_interval_seconds: number; poll_budget: number }; listings: { urgent_window_minutes: number } };
};

export type ControlKey = "ops.kill_switches" | "ops.maintenance" | "ops.min_version" | "ops.announcement";

export const CONTROL_KEYS: ControlKey[] = ["ops.kill_switches", "ops.maintenance", "ops.min_version", "ops.announcement"];

export const CONTROL_TITLES: Record<ControlKey, string> = {
  "ops.kill_switches": "Features",
  "ops.maintenance": "Maintenance banner",
  "ops.min_version": "App version",
  "ops.announcement": "Announcement",
};

/** What each switch stops when it is OFF — in the words a user would notice. */
export const SWITCHES: { key: keyof KillSwitches; label: string; off: string }[] = [
  { key: "posting", label: "Posting", off: "Nobody can post a new request, offer or job." },
  { key: "applications", label: "Applying and offering", off: "Nobody can apply to a job or offer their service on a request." },
  { key: "payments", label: "Payments", off: "Nobody can start an M-Pesa payment into escrow. Payments already made are unaffected." },
  { key: "promotions", label: "Promotions", off: "Nobody can buy a promotion. Running campaigns keep running." },
];

/** The app re-reads /config every 15 minutes, and the backend caches it for 60 s. */
export const PICKUP_NOTE = "Phones pick a change up within about 15 minutes, or straight away when the app is opened.";

export const DEFAULT_STORE_URL = "https://help24.co.ke/download";

export function controlValue(config: ClientConfig, key: ControlKey): Record<string, unknown> {
  switch (key) {
    case "ops.kill_switches": return config.ops.kill_switches;
    case "ops.maintenance": return config.ops.maintenance;
    case "ops.min_version": return config.ops.min_version;
    case "ops.announcement": return config.ops.announcement;
  }
}

// ── versions ────────────────────────────────────────────────────────────────

const VERSION = /^\d+\.\d+\.\d+$/;

export function isVersion(v: string): boolean {
  return VERSION.test(v);
}

/** -1, 0 or 1, segment by segment — the same comparison the app makes. */
export function compareVersions(a: string, b: string): number {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    if ((pa[i] ?? 0) !== (pb[i] ?? 0)) return (pa[i] ?? 0) < (pb[i] ?? 0) ? -1 : 1;
  }
  return 0;
}

/**
 * Problems that must block a version change. `latest` is the newest published
 * release, when known: a gate above it would send every user to a download
 * page that cannot satisfy it — the app would be unusable for everyone.
 */
export function minVersionProblems(v: MinVersion, latest: string | null): string[] {
  const out: string[] = [];
  for (const [field, label] of [["soft", "Suggest update below"], ["hard", "Require update below"]] as const) {
    const value = v[field].trim();
    if (value && !isVersion(value)) out.push(`${label}: write a version like 1.0.5, or leave it empty for none.`);
    if (value && isVersion(value) && latest && compareVersions(value, latest) > 0) {
      out.push(`${label}: ${value} has not been released — the newest download is ${latest}.`);
    }
  }
  if (isVersion(v.hard) && isVersion(v.soft) && compareVersions(v.hard, v.soft) > 0) {
    out.push("The required version cannot be higher than the suggested one.");
  }
  if ((v.hard || v.soft) && !v.store_url.trim()) out.push("Give the page the Update button opens.");
  return out;
}

/**
 * Everything that must block saving `value` under `key`. The app shows a
 * banner only when it has words (RemoteConfig shouldShow), so switching one on
 * with an empty message would look saved and show nothing.
 */
export function controlProblems(key: ControlKey, value: Record<string, unknown>, latest: string | null): string[] {
  if (key === "ops.min_version") return minVersionProblems(value as MinVersion, latest);
  if ((key === "ops.maintenance" || key === "ops.announcement") && value.active && !String(value.message ?? "").trim()) {
    return ["Write the message people will see — the app shows nothing without one."];
  }
  if (key === "ops.announcement" && String(value.url ?? "").trim() && !/^https:\/\//.test(String(value.url).trim())) {
    return ["The link must start with https://"];
  }
  return [];
}

// ── describing a change ─────────────────────────────────────────────────────

function onOff(b: unknown): string {
  return b ? "on" : "off";
}

function quote(s: unknown): string {
  const t = String(s ?? "").trim();
  return t ? `“${t}”` : "(none)";
}

/**
 * One line per field that changes, in plain words — what the confirmation
 * dialog shows and what the history reads back. Fields that do not change are
 * left out; an empty list means the change is a no-op.
 */
export function describeChange(key: ControlKey, before: Record<string, unknown>, after: Record<string, unknown>): string[] {
  const lines: string[] = [];
  const changed = (f: string) => JSON.stringify(before?.[f]) !== JSON.stringify(after?.[f]);

  if (key === "ops.kill_switches") {
    for (const s of SWITCHES) {
      if (changed(s.key)) lines.push(`${s.label}: ${onOff(before?.[s.key])} → ${onOff(after?.[s.key])}`);
    }
  } else if (key === "ops.maintenance") {
    if (changed("active")) lines.push(`Banner: ${onOff(before?.active)} → ${onOff(after?.active)}`);
    if (changed("message")) lines.push(`Message: ${quote(after?.message)}`);
  } else if (key === "ops.announcement") {
    if (changed("active")) lines.push(`Announcement: ${onOff(before?.active)} → ${onOff(after?.active)}`);
    if (changed("message")) lines.push(`Message: ${quote(after?.message)}`);
    if (changed("url")) lines.push(`Link: ${quote(after?.url)}`);
  } else if (key === "ops.min_version") {
    const gate = (v: unknown) => (String(v ?? "").trim() ? String(v) : "none");
    if (changed("soft")) lines.push(`Suggest update below: ${gate(before?.soft)} → ${gate(after?.soft)}`);
    if (changed("hard")) lines.push(`Require update below: ${gate(before?.hard)} → ${gate(after?.hard)}`);
    if (changed("message")) lines.push(`Message: ${quote(after?.message)}`);
    if (changed("store_url")) lines.push(`Update button opens: ${quote(after?.store_url)}`);
  }
  return lines;
}

/**
 * Whether the change takes something AWAY from users — a switch turned off, a
 * maintenance banner turned on, a required version raised. The dialog uses
 * the danger tone for these.
 */
export function isRestrictive(key: ControlKey, before: Record<string, unknown>, after: Record<string, unknown>): boolean {
  if (key === "ops.kill_switches") return SWITCHES.some((s) => before?.[s.key] !== false && after?.[s.key] === false);
  if (key === "ops.maintenance") return !before?.active && !!after?.active;
  if (key === "ops.min_version") {
    const b = String(before?.hard ?? ""), a = String(after?.hard ?? "");
    return !!a && (!b || (isVersion(a) && isVersion(b) && compareVersions(a, b) > 0));
  }
  return false;
}

/**
 * Dismissal of an announcement is remembered per id on each phone, so new
 * wording needs a new id or everyone who closed the old one never sees it.
 */
export function nextAnnouncementId(now = Date.now()): string {
  return `a-${now.toString(36)}`;
}
