import "server-only";
import { adminRequest } from "./api";

/**
 * The support Inbox (backend /admin/support, migration 138): mail to
 * support@ and info@ as conversations, answered by email as "Help24 Support".
 */

export type ConversationStatus = "open" | "waiting" | "closed";
export type InboxLabel = "support" | "general" | "security";

export type Conversation = {
  id: string;
  ref: string;
  label: InboxLabel;
  status: ConversationStatus;
  subject: string;
  contact_email: string;
  contact_name: string | null;
  user_id: string | null;
  started_by: "member" | "staff";
  last_message_at: string;
  created_at: string;
};

export type ConversationListItem = Conversation & {
  preview: { author: "member" | "staff"; body: string } | null;
};

export type SupportList = {
  counts: Record<ConversationStatus, number>;
  /** Conversations needing a reply, per inbox (absent from an older backend). */
  open_by_label?: Record<InboxLabel, number>;
  conversations: ConversationListItem[];
};

export type SupportMessage = {
  id: string;
  author: "member" | "staff";
  admin_id: string | null;
  admin_name: string | null;
  internal: boolean;
  channel: "email" | "app" | "note";
  body: string;
  full_body: string | null;
  sender_verified: boolean | null;
  attachment_count: number;
  delivery: "sending" | "sent" | "failed" | null;
  delivery_error: string | null;
  created_at: string;
};

export type SupportMember = {
  id: string;
  name: string | null;
  email: string | null;
  phone_number: string | null;
  created_at: string | null;
  last_seen: string | null;
};

export type SupportThread = {
  conversation: Conversation;
  member: SupportMember | null;
  messages: SupportMessage[];
};

export const STATUS_LABELS: Record<ConversationStatus, string> = {
  open: "Needs reply",
  waiting: "Waiting on member",
  closed: "Closed",
};

export function getSupportList(filter: { status?: ConversationStatus; label?: InboxLabel }): Promise<SupportList> {
  const q = new URLSearchParams();
  if (filter.status) q.set("status", filter.status);
  if (filter.label) q.set("label", filter.label);
  const qs = q.toString();
  return adminRequest<SupportList>(`/admin/support/conversations${qs ? `?${qs}` : ""}`);
}

export function getSupportThread(id: string): Promise<SupportThread> {
  return adminRequest<SupportThread>(`/admin/support/conversations/${encodeURIComponent(id)}`);
}
