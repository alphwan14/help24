/**
 * How recently a member actually USED Help24 — distinct from their account
 * standing (active / suspended / banned), which only says whether they are
 * allowed to. The Users page used to show a green "Active" for every account
 * that had not been sanctioned, including people last seen six months ago.
 *
 * Built from the two signals the app keeps on public.users:
 *   - last_seen  — stamped by the app's presence heartbeat every 60 s while it
 *                  is in the foreground (home_screen.dart), and on background;
 *   - last_login — stamped at each sign-in / profile sync.
 * `is_online` alone is not trusted: a crash or force-stop leaves it stuck true.
 * It counts only while the heartbeat behind it is fresh — the same 150 s rule
 * the app's chat screen uses (messages_screen.dart _presenceStaleAfter).
 */

export type ActivityState = "online" | "today" | "week" | "month" | "inactive" | "dormant" | "never";

export const ACTIVITY_ORDER: ActivityState[] = ["online", "today", "week", "month", "inactive", "dormant", "never"];

export const ACTIVITY_LABELS: Record<ActivityState, string> = {
  online: "Online now",
  today: "Active today",
  week: "This week",
  month: "This month",
  inactive: "Inactive",
  dormant: "Dormant",
  never: "Never opened",
};

/** One line each, for tooltips and the page legend. */
export const ACTIVITY_MEANING: Record<ActivityState, string> = {
  online: "The app is open on their phone right now",
  today: "Used the app in the last 24 hours",
  week: "Used the app in the last 7 days",
  month: "Used the app in the last 30 days",
  inactive: "Last used 30–90 days ago",
  dormant: "Not seen for more than 90 days",
  never: "Signed up but no activity recorded",
};

/** Pill tone per activity state — design-system tokens, light and dark. */
export const ACTIVITY_STYLES: Record<ActivityState, string> = {
  online: "bg-positive-100 text-positive-700",
  today: "bg-positive-100 text-positive-700",
  week: "bg-info-100 text-info-700",
  month: "bg-gray-100 text-gray-600",
  inactive: "bg-caution-100 text-caution-700",
  dormant: "bg-gray-100 text-gray-500",
  never: "bg-gray-100 text-gray-400",
};

const HEARTBEAT_STALE_MS = 150_000;
const DAY = 86_400_000;

export type ActivityInput = {
  last_seen?: string | null;
  last_login?: string | null;
  is_online?: boolean | null;
};

function ms(iso: string | null | undefined): number | null {
  if (!iso) return null;
  const t = Date.parse(iso);
  return Number.isFinite(t) ? t : null;
}

/** The latest sign of life, or null if there has never been one. */
export function lastActiveAt(u: ActivityInput): number | null {
  const a = ms(u.last_seen);
  const b = ms(u.last_login);
  if (a == null) return b;
  if (b == null) return a;
  return Math.max(a, b);
}

export function activityState(u: ActivityInput, now = Date.now()): ActivityState {
  const seen = ms(u.last_seen);
  if (u.is_online && seen != null && now - seen < HEARTBEAT_STALE_MS) return "online";
  const last = lastActiveAt(u);
  if (last == null) return "never";
  const age = now - last;
  if (age < DAY) return "today";
  if (age < 7 * DAY) return "week";
  if (age < 30 * DAY) return "month";
  if (age < 90 * DAY) return "inactive";
  return "dormant";
}

/** "just now", "12m ago", "3h ago", "2d ago", "5w ago", "4mo ago", "1y ago". */
export function agoLabel(at: number | null, now = Date.now()): string {
  if (at == null) return "—";
  const s = Math.max(0, Math.round((now - at) / 1000));
  if (s < 60) return "just now";
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.round(h / 24);
  if (d < 14) return `${d}d ago`;
  if (d < 60) return `${Math.round(d / 7)}w ago`;
  if (d < 365) return `${Math.round(d / 30)}mo ago`;
  return `${Math.round(d / 365)}y ago`;
}

export function isActivityState(v: unknown): v is ActivityState {
  return typeof v === "string" && (ACTIVITY_ORDER as string[]).includes(v);
}
