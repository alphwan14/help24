import React from "react";

/**
 * Single source of truth for a post's status badge in the ADMIN dashboard.
 *
 * The ARCHIVED state is derived ONLY from posts.archived_at and visually
 * overrides every other label (precedence: ARCHIVED > DISPUTED > COMPLETED >
 * ACTIVE). Do not duplicate this logic in screens — always render through here.
 */

export function isArchived(archivedAt: string | null | undefined): boolean {
  return Boolean(archivedAt);
}

/** Prominent ARCHIVED badge (+ optional "Removed from feed" secondary label). */
export function ArchivedBadge({ withSubtitle = false }: { withSubtitle?: boolean }) {
  return (
    <span className="inline-flex items-center gap-2">
      <span className="badge bg-gray-900 text-white font-bold tracking-wide">ARCHIVED</span>
      {withSubtitle && <span className="text-xs text-gray-400">Removed from feed</span>}
    </span>
  );
}

const STATUS_BADGE: Record<string, { label: string; cls: string }> = {
  disputed: { label: "Disputed", cls: "bg-red-100 text-red-700" },
  completed: { label: "Completed", cls: "bg-green-100 text-green-700" },
  cancelled: { label: "Cancelled", cls: "bg-gray-100 text-gray-600" },
  assigned: { label: "Assigned", cls: "bg-indigo-100 text-indigo-700" },
  open: { label: "Open", cls: "bg-blue-100 text-blue-700" },
};

/**
 * Post status badge with ARCHIVED precedence. Pass the canonical posts.status and
 * posts.archived_at; nothing else. When archived, the status is suppressed.
 */
export function PostStatusBadge({
  status,
  archivedAt,
  withSubtitle = false,
}: {
  status?: string | null;
  archivedAt?: string | null;
  withSubtitle?: boolean;
}) {
  if (isArchived(archivedAt)) return <ArchivedBadge withSubtitle={withSubtitle} />;
  const s = STATUS_BADGE[status ?? ""] ?? { label: status ?? "—", cls: "bg-gray-100 text-gray-600" };
  return <span className={`badge ${s.cls}`}>{s.label}</span>;
}

/** Faded row styling for archived rows in DataTable (`rowClassName`). */
export function archivedRowClass(archivedAt: string | null | undefined): string {
  return isArchived(archivedAt) ? "opacity-60 bg-gray-50/80" : "";
}
