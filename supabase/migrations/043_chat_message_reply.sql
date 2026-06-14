-- Migration 043: reply-to support for chat messages
--
-- reply_to_id      → FK to the message being replied to (text, not uuid, to match sender_id pattern)
-- reply_to_sender  → denormalised sender name of the quoted message (avoids a JOIN on render)
-- reply_to_preview → first 200 chars of the quoted message text (avoids a JOIN on render)
--
-- Denormalising sender + preview makes the bubble render O(1) without extra queries.

ALTER TABLE chat_messages
  ADD COLUMN IF NOT EXISTS reply_to_id       text,
  ADD COLUMN IF NOT EXISTS reply_to_sender   text,
  ADD COLUMN IF NOT EXISTS reply_to_preview  text;

CREATE INDEX IF NOT EXISTS idx_chat_messages_reply_to
  ON chat_messages (reply_to_id)
  WHERE reply_to_id IS NOT NULL;
