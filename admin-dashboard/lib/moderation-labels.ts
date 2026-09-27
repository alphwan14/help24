/**
 * Trust & Safety vocabulary for the dashboard: labels, badge styles and small
 * formatters. Safe to import from server AND client components (no secrets, no
 * server-only APIs).
 *
 * Colour follows the token rule the app uses: a tone means a STATE. Severity
 * and account status are the two things an operator must read at a glance, so
 * they are the only things that take strong colour; categories stay neutral.
 */

export const REPORT_CATEGORIES = [
  "scam_or_fraud",
  "suspicious_activity",
  "illegal_activity",
  "harassment",
  "threats",
  "inappropriate_content",
  "impersonation",
  "misleading_listing",
  "payment_issue",
  "spam",
  "unsafe_behavior",
  "other",
] as const;

export const CATEGORY_LABELS: Record<string, string> = {
  scam_or_fraud: "Scam or fraud",
  suspicious_activity: "Suspicious activity",
  illegal_activity: "Illegal activity",
  harassment: "Harassment or abuse",
  threats: "Threats or intimidation",
  inappropriate_content: "Inappropriate content",
  impersonation: "Fake identity",
  misleading_listing: "Misleading listing",
  payment_issue: "Payment issue",
  spam: "Spam",
  unsafe_behavior: "Unsafe behaviour",
  other: "Other",
};

export const REPORT_STATUSES = ["new", "under_review", "action_required", "resolved", "dismissed"] as const;
export type ReportStatus = (typeof REPORT_STATUSES)[number];

export const STATUS_LABELS: Record<string, string> = {
  new: "New",
  under_review: "Under review",
  action_required: "Action required",
  resolved: "Resolved",
  dismissed: "Dismissed",
};

export const STATUS_STYLES: Record<string, string> = {
  new: "bg-info-100 text-info-700",
  under_review: "bg-caution-100 text-caution-700",
  action_required: "bg-critical-100 text-critical-700",
  resolved: "bg-positive-100 text-positive-700",
  dismissed: "bg-gray-100 text-gray-500",
};

export const SEVERITIES = ["critical", "high", "medium", "low"] as const;
export type Severity = (typeof SEVERITIES)[number];

export const SEVERITY_LABELS: Record<string, string> = {
  critical: "Critical",
  high: "High",
  medium: "Medium",
  low: "Low",
};

/** The one solid badge in a row is Critical — a screen with two solid badges has none. */
export const SEVERITY_STYLES: Record<string, string> = {
  critical: "bg-critical-500 text-white",
  high: "bg-critical-100 text-critical-700",
  medium: "bg-caution-100 text-caution-700",
  low: "bg-gray-100 text-gray-600",
};

export const SEVERITY_DOT: Record<string, string> = {
  critical: "bg-critical-500",
  high: "bg-critical-400",
  medium: "bg-caution-500",
  low: "bg-gray-300",
};

export const ACCOUNT_STATUS_LABELS: Record<string, string> = {
  active: "Active",
  restricted: "Restricted",
  suspended: "Suspended",
  banned: "Banned",
};

export const ACCOUNT_STATUS_STYLES: Record<string, string> = {
  active: "bg-positive-100 text-positive-700",
  restricted: "bg-caution-100 text-caution-700",
  // Not a solid amber fill: white on the caution fill is 3.8:1, under AA at badge size.
  suspended: "bg-caution-100 text-caution-800 ring-1 ring-inset ring-caution-300 font-semibold",
  banned: "bg-critical-500 text-white",
};

export const TARGET_LABELS: Record<string, string> = {
  user: "Account",
  post: "Listing",
  application: "Application",
  message: "Message",
};

export const RESTRICTION_KIND_LABELS: Record<string, string> = {
  suspension: "Suspension",
  ban: "Permanent ban",
  messaging: "Messaging restricted",
  marketplace: "Marketplace restricted",
};

export const RESOLUTION_LABELS: Record<string, string> = {
  action_taken: "Action taken",
  no_action: "No action needed",
  dismissed: "Dismissed",
};

export const ACTION_LABELS: Record<string, string> = {
  report_triaged: "Report triaged",
  report_reopened: "Report reopened",
  report_resolved: "Report resolved",
  report_dismissed: "Report dismissed",
  note_added: "Internal note",
  warning_issued: "Warning issued",
  suspension_applied: "Suspended",
  ban_applied: "Banned",
  messaging_restricted: "Messaging restricted",
  marketplace_restricted: "Marketplace restricted",
  restriction_lifted: "Restriction lifted",
  content_removed: "Content hidden",
  content_restored: "Content restored",
  legacy_ban_imported: "Legacy ban carried over",
};

/** Ledger rows that CHANGED an account or its content, as opposed to paperwork. */
export const SANCTION_ACTIONS = new Set([
  "warning_issued",
  "suspension_applied",
  "ban_applied",
  "messaging_restricted",
  "marketplace_restricted",
  "restriction_lifted",
  "content_removed",
  "content_restored",
  "legacy_ban_imported",
]);

export const ACTION_TONE: Record<string, string> = {
  warning_issued: "bg-caution-100 text-caution-700",
  suspension_applied: "bg-caution-100 text-caution-800 ring-1 ring-inset ring-caution-300 font-semibold",
  ban_applied: "bg-critical-500 text-white",
  messaging_restricted: "bg-caution-100 text-caution-700",
  marketplace_restricted: "bg-caution-100 text-caution-700",
  restriction_lifted: "bg-positive-100 text-positive-700",
  content_removed: "bg-critical-100 text-critical-700",
  content_restored: "bg-positive-100 text-positive-700",
  report_dismissed: "bg-gray-100 text-gray-600",
  report_resolved: "bg-positive-100 text-positive-700",
  report_reopened: "bg-info-100 text-info-700",
  report_triaged: "bg-gray-100 text-gray-600",
  note_added: "bg-accent-100 text-accent-700",
  legacy_ban_imported: "bg-critical-100 text-critical-700",
};

export type AdminRole = "support_agent" | "senior_admin" | "super_admin";
const RANK: Record<AdminRole, number> = { support_agent: 1, senior_admin: 2, super_admin: 3 };

export function roleAtLeast(role: AdminRole, minimum: AdminRole): boolean {
  return RANK[role] >= RANK[minimum];
}

/** Mirrors SANCTION_MIN_ROLE in the backend (which is the enforcement). */
export const SANCTION_MIN_ROLE: Record<string, AdminRole> = {
  warning: "support_agent",
  messaging: "senior_admin",
  marketplace: "senior_admin",
  suspension: "senior_admin",
  ban: "super_admin",
};

// ── Formatting ─────────────────────────────────────────────────────────────

export function fmtDate(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString("en-KE", { day: "2-digit", month: "short", year: "numeric" });
}

export function fmtDateTime(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("en-KE", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/** "4h", "3d", "2mo" — for queue ages and "member for". */
export function age(iso: string | null | undefined, now = Date.now()): string {
  if (!iso) return "—";
  const ms = Math.max(0, now - Date.parse(iso));
  const h = Math.floor(ms / 3_600_000);
  if (h < 1) return "<1h";
  if (h < 24) return `${h}h`;
  const d = Math.floor(h / 24);
  if (d < 60) return `${d}d`;
  const mo = Math.floor(d / 30);
  if (mo < 24) return `${mo}mo`;
  return `${Math.floor(d / 365)}y`;
}

/** How overdue an open report is: under a day is fine, over three is a problem. */
export function ageTone(iso: string | null | undefined, now = Date.now()): string {
  if (!iso) return "text-gray-400";
  const h = (now - Date.parse(iso)) / 3_600_000;
  if (h >= 72) return "text-critical-600 font-semibold";
  if (h >= 24) return "text-caution-600 font-semibold";
  return "text-gray-500";
}

export function fmtKES(n: number | null | undefined): string {
  return n == null ? "—" : `KES ${Number(n).toLocaleString("en-KE")}`;
}

export function humanise(s: string | null | undefined): string {
  if (!s) return "";
  const t = s.replace(/_/g, " ");
  return t.charAt(0).toUpperCase() + t.slice(1);
}
