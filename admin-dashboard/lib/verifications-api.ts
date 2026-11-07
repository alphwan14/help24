import "server-only";
import { adminRequest } from "./api";

/**
 * Provider verification readers — server components only. Every read goes
 * through /admin/verifications/* (AdminAuthGuard + RBAC); document images are
 * reached only through the short-lived signed links the backend returns.
 */

export type VerificationStatus = "pending" | "approved" | "rejected";
export type VerificationKind = "id" | "care";

export interface VerificationPerson {
  id: string;
  name: string | null;
  profession: string | null;
  phone_number: string | null;
  avatar_url: string | null;
  profile_image: string | null;
  created_at: string | null;
}

export interface VerificationRow {
  id: string;
  user_id: string;
  kind: VerificationKind;
  document_type: string;
  document_label: string;
  file_count: number;
  status: VerificationStatus;
  submitted_at: string;
  reviewed_at: string | null;
  reviewed_by: string | null;
  rejection_reason: string | null;
  expires_at: string | null;
  files_deleted_at: string | null;
}

export interface VerificationListItem extends VerificationRow {
  person: VerificationPerson | null;
}

export interface VerificationFile {
  role: string;
  is_pdf: boolean;
  url: string | null;
  error: string | null;
}

export interface VettedListing {
  id: string;
  title: string;
  category: string;
  status: string;
  vetting_label: "certificate_pending" | "not_verified" | null;
  vetting_hide_at: string | null;
  archived_by: string | null;
  created_at: string;
  tier: "id" | "care" | null;
}

export interface VerificationDetail extends VerificationListItem {
  files: VerificationFile[];
  state: { id_verified: boolean; care_status: "checked" | "pending" | "none"; care_expires_at: string | null } | null;
  history: VerificationRow[];
  listings: VettedListing[];
}

export interface VerificationMeta {
  rejection_reasons: string[];
  document_labels: Record<string, string>;
  review_target_hours: number;
}

export interface VerificationSummary {
  pending: number;
  oldest_submitted_at: string | null;
  overdue: number;
}

export function listVerifications(status: VerificationStatus): Promise<{ items: VerificationListItem[] }> {
  return adminRequest(`/admin/verifications?status=${status}`);
}

export function getVerification(id: string): Promise<VerificationDetail> {
  return adminRequest(`/admin/verifications/${encodeURIComponent(id)}`);
}

export function getVerificationMeta(): Promise<VerificationMeta> {
  return adminRequest("/admin/verifications/meta");
}

export function getVerificationSummary(): Promise<VerificationSummary> {
  return adminRequest("/admin/verifications/summary");
}

export const KIND_LABELS: Record<VerificationKind, string> = { id: "ID check", care: "Care check" };

export const STATUS_LABELS: Record<VerificationStatus, string> = {
  pending: "Waiting for review",
  approved: "Approved",
  rejected: "Rejected",
};
