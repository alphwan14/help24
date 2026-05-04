-- =============================================================================
-- Migration 024: Message read status + typing indicator
-- =============================================================================
-- Adds:
--   chat_messages.status    text  'sent' | 'seen'  (delivered skipped: needs push infra)
--   chat_messages.seen_at   timestamptz
--   chats.typing_user_id    text  (who is currently typing)
--   chats.typing_at         timestamptz  (when they last typed — expires after 4s in app)
-- =============================================================================

-- Message status
ALTER TABLE public.chat_messages
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'sent';

ALTER TABLE public.chat_messages
  ADD COLUMN IF NOT EXISTS seen_at timestamptz;

-- Constrain valid values (safe: only adds if constraint doesn't already exist)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'chat_messages_status_check'
  ) THEN
    ALTER TABLE public.chat_messages
      ADD CONSTRAINT chat_messages_status_check
      CHECK (status IN ('sent', 'seen'));
  END IF;
END $$;

-- Index: efficient bulk-update of unseen messages for a chat
CREATE INDEX IF NOT EXISTS idx_chat_messages_unseen
  ON public.chat_messages(chat_id, sender_id, status)
  WHERE status = 'sent';

-- Typing state on chats (lightweight: single row update, no extra table)
ALTER TABLE public.chats
  ADD COLUMN IF NOT EXISTS typing_user_id text;

ALTER TABLE public.chats
  ADD COLUMN IF NOT EXISTS typing_at timestamptz;

-- Verify
-- SELECT id, status, seen_at FROM public.chat_messages LIMIT 5;
-- SELECT id, typing_user_id, typing_at FROM public.chats LIMIT 5;
