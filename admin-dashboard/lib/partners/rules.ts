/**
 * Partner rules, shared by the admin dashboard and the partner portal — the
 * same words and the same numbers on both, by construction.
 *
 * The qualifying rule itself is computed in the database view
 * partner_member_progress (migration 128) so statements can reuse it; this
 * file only reads its columns. Pure: no fetches, so it is tested directly.
 */

export type ProgressRow = {
  member_id: string;
  agent_id: string;
  method: "code" | "link" | "qr";
  claimed_at: string;
  joined_at: string;
  window_ends_at: string;
  active_days: number;
  posts_14d: number;
  offers_14d: number;
  account_status: string;
};

export type MemberStatus = "qualified" | "in_progress" | "not_qualified";

export const STATUS_LABELS: Record<MemberStatus, string> = {
  qualified: "Qualified",
  in_progress: "In progress",
  not_qualified: "Did not qualify",
};

export const STATUS_STYLES: Record<MemberStatus, string> = {
  qualified: "bg-positive-100 text-positive-700",
  in_progress: "bg-info-100 text-info-700",
  not_qualified: "bg-gray-100 text-gray-500",
};

export const METHOD_LABELS: Record<ProgressRow["method"], string> = {
  code: "Typed the code",
  link: "Agent's link",
  qr: "Agent's QR code",
};

export const KIND_LABELS: Record<string, string> = {
  onboarding: "Onboarding",
  marketing: "Marketing",
  research: "Research",
};

/** Days of use that count, out of the first 14. */
export const ACTIVE_DAYS_NEEDED = 2;

const BLOCKED = new Set(["suspended", "banned"]);

export function inGoodStanding(r: Pick<ProgressRow, "account_status">): boolean {
  return !BLOCKED.has(r.account_status);
}

/** The member did something on Help24 in their first 14 days. */
export function contributed(r: Pick<ProgressRow, "posts_14d" | "offers_14d">): boolean {
  return r.posts_14d + r.offers_14d > 0;
}

export function memberStatus(r: ProgressRow, now = Date.now()): MemberStatus {
  const engaged = r.active_days >= ACTIVE_DAYS_NEEDED || contributed(r);
  if (engaged && inGoodStanding(r)) return "qualified";
  return Date.parse(r.window_ends_at) > now ? "in_progress" : "not_qualified";
}

/** What an agent can do to help a member who is still in progress. */
export function nextStep(r: ProgressRow, now = Date.now()): string | null {
  if (memberStatus(r, now) !== "in_progress") return null;
  if (!inGoodStanding(r)) return "Their account is restricted — they can't qualify while it is.";
  const left = Math.max(0, Math.ceil((Date.parse(r.window_ends_at) - now) / 86400_000));
  const days = ACTIVE_DAYS_NEEDED - r.active_days;
  return `Needs ${days} more day${days === 1 ? "" : "s"} of using Help24, or one post or offer — ${left} day${left === 1 ? "" : "s"} left.`;
}

export type Summary = { credited: number; qualified: number; inProgress: number; notQualified: number; thisWeek: number; byMethod: Record<ProgressRow["method"], number> };

export function summarise(rows: ProgressRow[], now = Date.now()): Summary {
  const s: Summary = { credited: rows.length, qualified: 0, inProgress: 0, notQualified: 0, thisWeek: 0, byMethod: { code: 0, link: 0, qr: 0 } };
  for (const r of rows) {
    const st = memberStatus(r, now);
    if (st === "qualified") s.qualified++;
    else if (st === "in_progress") s.inProgress++;
    else s.notQualified++;
    if (now - Date.parse(r.claimed_at) < 7 * 86400_000) s.thisWeek++;
    s.byMethod[r.method] = (s.byMethod[r.method] ?? 0) + 1;
  }
  return s;
}

/** Sign-ups per week (Monday-based, Nairobi), oldest first, `weeks` long. */
export function weeklyCounts(rows: Pick<ProgressRow, "claimed_at">[], weeks: number, now = Date.now()): { week: string; count: number }[] {
  const EAT = 3 * 3600_000;
  const startOfWeek = (t: number) => {
    const d = new Date(t + EAT);
    const day = (d.getUTCDay() + 6) % 7;
    return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - day);
  };
  const current = startOfWeek(now);
  const out = Array.from({ length: weeks }, (_, i) => {
    const t = current - (weeks - 1 - i) * 7 * 86400_000;
    return { week: new Date(t).toISOString().slice(0, 10), count: 0 };
  });
  for (const r of rows) {
    const idx = out.findIndex((w) => w.week === new Date(startOfWeek(Date.parse(r.claimed_at))).toISOString().slice(0, 10));
    if (idx >= 0) out[idx].count++;
  }
  return out;
}

// ── What an agent may see of a member ───────────────────────────────────────

/** First name only. */
export function maskName(name: string | null | undefined): string {
  const first = (name ?? "").trim().split(/\s+/)[0];
  return first ? first : "New member";
}

/** The last 3 digits only: "•••• ••• 678". */
export function maskPhone(phone: string | null | undefined): string {
  const d = (phone ?? "").replace(/\D/g, "");
  return d.length >= 3 ? `•••• ••• ${d.slice(-3)}` : "—";
}

// ── Invitations ─────────────────────────────────────────────────────────────

/** A one-time invitation token: 32 random bytes, URL-safe. */
export function newInviteToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Buffer.from(bytes).toString("base64url");
}

/** What the database stores instead of the token (migration 128). */
export async function hashInviteToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return Buffer.from(digest).toString("hex");
}
