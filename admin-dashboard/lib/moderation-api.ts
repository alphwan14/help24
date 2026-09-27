import "server-only";
import { ApiError, adminRequest, type AdminRole } from "./api";

/**
 * Trust & Safety readers — server components only.
 *
 * Same architecture as the disputes centre (lib/api.ts): NestJS is the single
 * source of truth, the admin bearer token lives in an httpOnly cookie and is
 * attached here, server-side. This module never touches Supabase directly —
 * every read goes through /admin/moderation/*, behind AdminAuthGuard and RBAC.
 */

type Json = Record<string, unknown>;

export interface AdminBrief {
  id: string;
  name: string;
  email: string;
  role: AdminRole;
}

export interface PersonBrief {
  id: string;
  name?: string;
  avatar?: string | null;
  member_since?: string;
  account_status?: string;
  open_reports_from_distinct_people?: number;
}

export type ReportListItem = {
  id: string;
  reference: string;
  reporter_id: string;
  reported_user_id: string;
  target_type: "user" | "post" | "application" | "message";
  target_id: string;
  target_label: string;
  reason: string;
  details: string;
  status: string;
  severity: string;
  source: string;
  assigned_admin_id: string | null;
  assigned_at: string | null;
  created_at: string;
  updated_at: string;
  resolved_at: string | null;
  resolution: string | null;
  evidence_count: number;
  target_snapshot: Json;
  reporter: PersonBrief;
  reported: PersonBrief;
  assigned_admin: AdminBrief | null;
  [key: string]: unknown;
};

export interface ReportPage {
  total: number;
  limit: number;
  offset: number;
  items: ReportListItem[];
}

export interface ModerationSummary {
  open_reports: number;
  critical_open: number;
  high_open: number;
  unassigned_open: number;
  assigned_to_me: number;
  reports_last_24h: number;
  suspended_accounts: number;
  banned_accounts: number;
  restricted_accounts: number;
  actions_last_7d: number;
}

export type LedgerEntry = {
  id: string;
  reference: string;
  target_user_id: string;
  action_type: string;
  actor_type: "admin" | "system";
  admin_id: string | null;
  admin_email: string | null;
  admin_role: string | null;
  report_id: string | null;
  restriction_id: string | null;
  content_type: string | null;
  content_id: string | null;
  reason: string;
  internal_note: string | null;
  previous_state: Json;
  new_state: Json;
  metadata: Json;
  request_id: string | null;
  created_at: string;
  chain_seq: number;
  target_user?: PersonBrief;
  [key: string]: unknown;
};

export interface Signals {
  requests_created: number;
  offers_created: number;
  jobs_created: number;
  listings_hidden_by_moderation: number;
  applications_made: number;
  completed_jobs: number;
  avg_rating: number | null;
  total_reviews: number;
  completion_rate: number | null;
  disputes_raised: number;
  disputes_against: number;
  failed_payments: number;
  cancelled_as_provider: number;
  reports_received: number;
  reports_received_open: number;
  reports_received_distinct_reporters: number;
  reports_received_distinct_reporters_30d: number;
  reports_received_dismissed: number;
  reports_received_actioned: number;
  reports_made: number;
  reports_made_dismissed: number;
  warnings: number;
  suspensions: number;
  bans: number;
  partial_restrictions: number;
  content_removals: number;
}

export interface ActiveRestriction {
  id: string;
  reference: string;
  kind: string;
  reason: string;
  starts_at: string;
  ends_at: string | null;
  created_at: string;
}

export interface AccountSummary {
  user: {
    id: string;
    name: string | null;
    email: string | null;
    phone_number: string | null;
    created_at: string;
    last_login: string | null;
    profession: string | null;
    is_verified: boolean;
    role: string;
    account_type: string;
    avatar: string | null;
    bio: string | null;
  } | null;
  sign_in: {
    providers: string[];
    phone_verified: boolean;
    email_verified: boolean;
    created_at: string | null;
    last_sign_in: string | null;
    disabled: boolean;
  } | null;
  account: { status: string; active_restrictions: ActiveRestriction[] };
  signals: Signals;
}

export interface TimelineEvent {
  at: string;
  layer: "platform" | "allegation" | "decision";
  kind: string;
  label: string;
  detail?: string;
}

export interface ConversationMessage {
  id: string;
  sender_id: string;
  content: string;
  type: string;
  attachment_url: string | null;
  created_at: string;
  deleted_for_everyone: boolean;
  from: "reported" | "reporter" | "other";
  is_reported_message: boolean;
}

export interface JobContext {
  post: Json & { id: string; title: string; type: string; status: string; price: number; created_at: string; archived_at: string | null };
  reported_role: "client" | "selected_provider" | "applicant" | "other";
  applications_count: number;
  reported_applied_at: string | null;
  transactions: Array<Json & { id: string; status: string; amount: number; total_paid: number; created_at: string }>;
  escrow: Array<Json & { status: string; released_at: string | null }>;
  completions: Array<Json & { status: string; created_at: string }>;
  disputes: Array<Json & { id: string; status: string; reason: string; created_at: string; raised_by_role: string | null }>;
}

export interface EvidenceItem {
  path: string;
  mime_type: string;
  size_bytes?: number;
  signed_url: string | null;
}

export interface ReportInvestigation {
  report: ReportListItem & {
    evidence: EvidenceItem[];
    chat_id: string | null;
    post_id: string | null;
    message_id: string | null;
    application_id: string | null;
    resolution_reason: string | null;
    resolved_by_admin: AdminBrief | null;
  };
  reporter: PersonBrief & { reports_made: number; reports_made_actioned: number; reports_made_dismissed: number };
  reported: AccountSummary;
  target: {
    type: string;
    id: string;
    snapshot: Json;
    live: Json | null;
    changed_since_report: boolean | null;
  };
  conversation: { chat_id: string; post_id: string | null; basis: string; messages: ConversationMessage[] } | null;
  job: JobContext | null;
  related_reports: Array<Json & {
    id: string; reference: string; reason: string; status: string; severity: string; created_at: string;
    same_target: boolean; same_reporter: boolean; target_label: string; target_type: string;
  }>;
  decisions: LedgerEntry[];
  notes: LedgerEntry[];
  timeline: TimelineEvent[];
}

export interface RestrictionRecord extends ActiveRestriction {
  user_id: string;
  report_id: string | null;
  created_by: string | null;
  created_by_system: boolean;
  lifted_at: string | null;
  lifted_by: string | null;
  lift_reason: string | null;
  active: boolean;
  created_by_admin: AdminBrief | null;
  lifted_by_admin: AdminBrief | null;
}

export interface UserModerationProfile extends AccountSummary {
  restrictions: RestrictionRecord[];
  ledger: LedgerEntry[];
  reports_received: ReportListItem[];
  reports_made: ReportListItem[];
  recent_posts: Array<Json & { id: string; title: string; type: string; status: string; created_at: string; archived_at: string | null; archived_by: string | null }>;
  recent_applications: Array<Json & { id: string; post_id: string; message: string; created_at: string; posts: { title: string; type: string } | null }>;
  timeline: TimelineEvent[];
}

export type RestrictedRow = ActiveRestriction & {
  user_id: string;
  report_id: string | null;
  created_by_system: boolean;
  user: PersonBrief;
  created_by_admin: AdminBrief | null;
  [key: string]: unknown;
};

export interface AuditPage {
  total: number;
  limit: number;
  offset: number;
  items: LedgerEntry[];
}

export interface AuditIntegrity {
  rows: number;
  edited_rows: number;
  broken_links: number;
  sequence_gaps: number;
  intact: boolean;
  checked_at: string;
}

export type Settled<T> = { ok: true; data: T } | { ok: false; status: number; error: string };

/**
 * A read that reports its failure instead of throwing it. Pages render the
 * failure as an error state — never as an empty list, which would claim there
 * is nothing to review.
 */
export async function settle<T>(promise: Promise<T>): Promise<Settled<T>> {
  try {
    return { ok: true, data: await promise };
  } catch (err) {
    if (err instanceof ApiError) {
      const hint =
        err.status === 403
          ? "Your admin role cannot see this."
          : err.status === 503 || err.status >= 500
            ? `${err.message} The Trust & Safety service may still be starting, or its database migrations are not applied yet.`
            : err.message;
      return { ok: false, status: err.status, error: hint };
    }
    return { ok: false, status: 0, error: "Unexpected error while loading." };
  }
}

function qs(params: Record<string, string | number | undefined | null>): string {
  const entries = Object.entries(params).filter(([, v]) => v !== undefined && v !== null && v !== "");
  if (entries.length === 0) return "";
  return "?" + entries.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`).join("&");
}

export function getModerationSummary(): Promise<ModerationSummary> {
  return adminRequest<ModerationSummary>("/admin/moderation/summary");
}

export function listReports(params: Record<string, string | number | undefined>): Promise<ReportPage> {
  return adminRequest<ReportPage>(`/admin/moderation/reports${qs(params)}`);
}

export function getReportInvestigation(id: string): Promise<ReportInvestigation> {
  return adminRequest<ReportInvestigation>(`/admin/moderation/reports/${encodeURIComponent(id)}`);
}

export function getUserModeration(userId: string): Promise<UserModerationProfile> {
  return adminRequest<UserModerationProfile>(`/admin/moderation/users/${encodeURIComponent(userId)}`);
}

export function listRestricted(kind?: string): Promise<RestrictedRow[]> {
  return adminRequest<RestrictedRow[]>(`/admin/moderation/restricted${qs({ kind })}`);
}

export function listAudit(params: Record<string, string | number | undefined>): Promise<AuditPage> {
  return adminRequest<AuditPage>(`/admin/moderation/audit${qs(params)}`);
}

export function getAuditIntegrity(): Promise<AuditIntegrity> {
  return adminRequest<AuditIntegrity>("/admin/moderation/audit/integrity");
}

export function listModerationAdmins(): Promise<AdminBrief[]> {
  return adminRequest<AdminBrief[]>("/admin/moderation/admins");
}
