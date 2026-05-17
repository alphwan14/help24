-- =============================================================================
-- Migration 027: Performance indexes
-- =============================================================================
-- Adds indexes that eliminate full-table scans found during perf audit.
-- All CREATE INDEX calls use IF NOT EXISTS — safe to re-run.
-- =============================================================================

-- Compound index: chats deduplication + sort (covers the canonical pair lookup
-- used by createChat and the OR filter used by _fetchConversations).
CREATE INDEX IF NOT EXISTS idx_chats_user1_user2
  ON public.chats(user1, user2);

-- Index on chat_messages.sender_id: speeds up markMessagesSeen() which
-- filters by chat_id AND neq sender_id on tables with many senders per chat.
CREATE INDEX IF NOT EXISTS idx_chat_messages_sender_id
  ON public.chat_messages(sender_id);

-- Compound covering index for the "unread messages for this user" query:
-- chat_id + status filter used in mark-as-seen bulk update.
-- (Complements the partial index added in migration 024.)
CREATE INDEX IF NOT EXISTS idx_chat_messages_chat_status
  ON public.chat_messages(chat_id, status);

-- Index on chats.updated_at already exists (migration 008).
-- Index on chat_messages(chat_id, created_at DESC) already exists (migration 008).
-- No duplicate indexes created here.
