-- Migration 042: soft-delete support for chat messages
--
-- deleted_for_everyone = true → message replaced with "This message was deleted"
--   • Only the original sender may set this flag (enforced client-side, 15-min window)
--   • Row is preserved for audit / dispute evidence
-- deleted_at              → when the deletion was performed
--
-- No hard-delete: escrow / dispute flows require message history to remain intact.

ALTER TABLE chat_messages
  ADD COLUMN IF NOT EXISTS deleted_for_everyone boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS deleted_at           timestamptz;

-- Partial index: fast queries for admin / moderation dashboards
CREATE INDEX IF NOT EXISTS idx_chat_messages_deleted
  ON chat_messages (chat_id, deleted_at)
  WHERE deleted_for_everyone = true;

-- RLS: allow sender to update their own messages (sets deleted_for_everyone)
-- The 15-minute window is enforced in client code; this policy allows the update.
-- CREATE POLICY does not support IF NOT EXISTS in PG15, so guard with a DO block.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'chat_messages'
      AND policyname = 'sender_can_soft_delete'
  ) THEN
    CREATE POLICY "sender_can_soft_delete"
      ON chat_messages
      FOR UPDATE
      USING  (sender_id = auth.uid()::text)
      WITH CHECK (sender_id = auth.uid()::text);
  END IF;
END
$$;
