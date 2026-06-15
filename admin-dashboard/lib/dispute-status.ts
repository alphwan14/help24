/**
 * Dispute status normalization. The NestJS backend is authoritative; this maps
 * its status strings to canonical UI buckets. Legacy values (from the pre-
 * arbitration schema) are folded into the new lifecycle so historical rows still
 * render correctly.
 *
 * Canonical lifecycle: open → reviewing → resolved | escalated  (+ merged)
 */

export type CanonicalStatus =
  | "open"
  | "reviewing"
  | "resolved"
  | "escalated"
  | "merged";

const LEGACY_MAP: Record<string, CanonicalStatus> = {
  under_review: "reviewing",
  resolved_release: "resolved",
  resolved_refund: "resolved",
  resolved_partial: "resolved",
};

export function normalizeStatus(status: string): CanonicalStatus {
  if (
    status === "open" ||
    status === "reviewing" ||
    status === "resolved" ||
    status === "escalated" ||
    status === "merged"
  ) {
    return status;
  }
  return LEGACY_MAP[status] ?? "open";
}

export const STATUS_STYLES: Record<CanonicalStatus, string> = {
  open: "bg-red-100 text-red-700",
  reviewing: "bg-orange-100 text-orange-700",
  resolved: "bg-green-100 text-green-700",
  escalated: "bg-purple-100 text-purple-700",
  merged: "bg-gray-100 text-gray-600",
};

export const STATUS_LABELS: Record<CanonicalStatus, string> = {
  open: "Open",
  reviewing: "Reviewing",
  resolved: "Resolved",
  escalated: "Escalated",
  merged: "Merged",
};

/** True when the case is closed (no further decisions possible). */
export function isTerminal(status: string): boolean {
  const s = normalizeStatus(status);
  return s === "resolved" || s === "escalated" || s === "merged";
}

export const PRIORITY_STYLES: Record<string, string> = {
  low: "bg-slate-100 text-slate-600",
  medium: "bg-blue-100 text-blue-700",
  high: "bg-amber-100 text-amber-700",
  critical: "bg-red-100 text-red-700",
};

/** Human-friendly SLA age from a millisecond duration. */
export function formatSlaAge(ms: number): string {
  const hours = Math.floor(ms / 3_600_000);
  if (hours < 1) return "< 1h";
  if (hours < 24) return `${hours}h`;
  const days = Math.floor(hours / 24);
  return `${days}d ${hours % 24}h`;
}
