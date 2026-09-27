import { AdminRole } from '../admin/auth/admin-role';

/**
 * The Trust & Safety vocabulary, in one file.
 *
 * The DATABASE is the authority for every rule here — migration 114 validates
 * categories per target, computes severity and decides what each restriction
 * blocks (`moderation_denial`). These constants exist so the API can reject a
 * malformed request before it reaches Postgres and so the type system can
 * name things. `moderation.constants.spec.ts` pins them against
 * supabase/tests/trust-safety/report_taxonomy.json, which the database test
 * suite pins against the SQL — so the three cannot drift apart silently.
 */

export const REPORT_CATEGORIES = [
  'scam_or_fraud',
  'suspicious_activity',
  'illegal_activity',
  'harassment',
  'threats',
  'inappropriate_content',
  'impersonation',
  'misleading_listing',
  'payment_issue',
  'spam',
  'unsafe_behavior',
  'other',
] as const;
export type ReportCategory = (typeof REPORT_CATEGORIES)[number];

export const REPORT_TARGET_TYPES = ['user', 'post', 'application', 'message'] as const;
export type ReportTargetType = (typeof REPORT_TARGET_TYPES)[number];

export const REPORT_STATUSES = ['new', 'under_review', 'action_required', 'resolved', 'dismissed'] as const;
export type ReportStatus = (typeof REPORT_STATUSES)[number];

/** A report still waiting on a decision. */
export const OPEN_REPORT_STATUSES: readonly ReportStatus[] = ['new', 'under_review', 'action_required'];

export const SEVERITIES = ['low', 'medium', 'high', 'critical'] as const;
export type Severity = (typeof SEVERITIES)[number];

/**
 * What a restriction can take away. Mirrors `moderation_capabilities()` — the
 * backend names a capability on a route with `@Restrict`, and the database
 * decides whether the caller has it.
 */
export const CAPABILITIES = [
  'post',
  'apply',
  'hire',
  'pay',
  'message',
  'promote',
  'review',
  'complete',
  'payout_config',
] as const;
export type Capability = (typeof CAPABILITIES)[number];

/** Why a capability was refused. The strings `moderation_denial` returns. */
export const DENIALS = ['banned', 'suspended', 'messaging_restricted', 'marketplace_restricted'] as const;
export type Denial = (typeof DENIALS)[number];

export const SANCTION_KINDS = ['warning', 'suspension', 'ban', 'messaging', 'marketplace'] as const;
export type SanctionKind = (typeof SANCTION_KINDS)[number];

export type RestrictionKind = Exclude<SanctionKind, 'warning'>;

/**
 * WHO MAY DO WHAT — the RBAC ladder the existing disputes centre already uses
 * (support_agent < senior_admin < super_admin), applied to moderation.
 *
 *   support_agent  review, investigate, triage, note, dismiss/resolve, warn,
 *                  hide or restore a single listing or message
 *   senior_admin   + suspend, restrict messaging or marketplace, lift those
 *   super_admin    + permanent ban, lift a ban, sanction an admin's own
 *                  marketplace account
 *
 * Deliberately not a new role system: three people currently hold super_admin,
 * and the ladder that governs money decisions is the right one to govern
 * account decisions too.
 */
export const SANCTION_MIN_ROLE: Readonly<Record<SanctionKind, AdminRole>> = {
  warning: 'support_agent',
  messaging: 'senior_admin',
  marketplace: 'senior_admin',
  suspension: 'senior_admin',
  ban: 'super_admin',
};

export const LIFT_MIN_ROLE: Readonly<Record<RestrictionKind, AdminRole>> = {
  messaging: 'senior_admin',
  marketplace: 'senior_admin',
  suspension: 'senior_admin',
  ban: 'super_admin',
};

/** Every row type the ledger can hold (moderation_actions.action_type). */
export const ACTION_TYPES = [
  'report_triaged',
  'report_reopened',
  'report_resolved',
  'report_dismissed',
  'note_added',
  'warning_issued',
  'suspension_applied',
  'ban_applied',
  'messaging_restricted',
  'marketplace_restricted',
  'restriction_lifted',
  'content_removed',
  'content_restored',
  'legacy_ban_imported',
] as const;
export type ActionType = (typeof ACTION_TYPES)[number];

/** The evidence bucket. Shared with the disputes centre: Help24 has ONE
 *  private, service-role-only evidence store (10 MB, images/PDF), and a report
 *  screenshot is the same kind of object as a dispute photo. Report uploads
 *  live under `reports/<reporter uid>/`, which migration 114 enforces. */
export const EVIDENCE_BUCKET = 'dispute-evidence';
export const MAX_REPORT_EVIDENCE = 3;
export const REPORT_EVIDENCE_MIME: Readonly<Record<string, string>> = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
};
export const MAX_EVIDENCE_BYTES = 10 * 1024 * 1024;

/** A short, quotable reference for a report, restriction or action id — the
 *  same derivation `my_account_status()` uses, so what a user reads to support
 *  is what an admin can search for. */
export function referenceOf(id: string): string {
  return id.replace(/-/g, '').slice(0, 8).toUpperCase();
}
