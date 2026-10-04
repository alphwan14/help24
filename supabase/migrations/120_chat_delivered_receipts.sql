-- 120 — Delivered receipts for chat messages (the second tick).
--
-- WHY
-- The chat showed three sending states: queued, sent and read. "Sent" meant the
-- server had the row; nothing said whether it had reached the other phone. The
-- redesign adds DELIVERED — two grey ticks — set by the RECIPIENT'S app the
-- moment a message lands on its device: in an open chat, in the conversation
-- list, or by push while the app is closed (the data-only FCM background
-- handler acknowledges it).
--
-- Read receipts already work the same way: the recipient's app updates its
-- copy of the row (`status = 'seen'`) under the participant RLS policy, and the
-- sender sees the change through the realtime UPDATE feed. Delivered follows
-- that path exactly.
--
-- WHY A COLUMN AND NOT A THIRD STATUS
-- `chat_messages_status_check` allows only 'sent' and 'seen', and the read
-- path filters on `status <> 'seen'`. Writing 'delivered' into `status` would
-- race it: a delivered ack landing after the read could pull a read message
-- back to grey ticks. A separate timestamp cannot — the app derives
-- read > delivered > sent, and a read message stays read whatever
-- `delivered_at` says. It also records WHEN, which a dispute can use.
--
-- WHAT
--   * `chat_messages.delivered_at timestamptz` — null until acknowledged.
--   * A guard: it is set once, never moved or cleared, and never by the
--     message's own sender (only the recipient's phone can say it arrived).
--     The participant RLS policy already limits the write to the two people
--     in the chat.
--
-- No backfill. Existing messages stay at one tick (or read, if seen) — the
-- honest answer, since nobody acknowledged them. No API change: the app writes
-- the column directly, as it writes `seen_at`.
--
-- APPLY: safe at any time. The app ships before this is applied and degrades:
-- until the column exists its acknowledgement is refused (42703 / PGRST204),
-- the app stops trying for six hours, and sent messages stay at one tick.
-- Idempotent.
--
-- ROLLBACK:
--   drop trigger if exists trg_chat_messages_delivered_guard on public.chat_messages;
--   drop function if exists public.fn_chat_messages_delivered_guard();
--   alter table public.chat_messages drop column if exists delivered_at;

ALTER TABLE public.chat_messages
  ADD COLUMN IF NOT EXISTS delivered_at timestamptz;

COMMENT ON COLUMN public.chat_messages.delivered_at IS
  'When the recipient''s app acknowledged the message (second tick). Set once, by the recipient only.';

CREATE OR REPLACE FUNCTION public.fn_chat_messages_delivered_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.delivered_at IS NOT DISTINCT FROM OLD.delivered_at THEN
    RETURN NEW;
  END IF;
  -- Once acknowledged, the time is the record: never moved, never cleared.
  IF OLD.delivered_at IS NOT NULL THEN
    NEW.delivered_at := OLD.delivered_at;
    RETURN NEW;
  END IF;
  -- Only the recipient's phone may say the message reached it.
  IF (auth.jwt() ->> 'user_id') IS NOT DISTINCT FROM NEW.sender_id THEN
    NEW.delivered_at := OLD.delivered_at;
    RETURN NEW;
  END IF;
  -- The server's clock, not the phone's.
  NEW.delivered_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_chat_messages_delivered_guard ON public.chat_messages;
CREATE TRIGGER trg_chat_messages_delivered_guard
  BEFORE UPDATE OF delivered_at ON public.chat_messages
  FOR EACH ROW EXECUTE FUNCTION public.fn_chat_messages_delivered_guard();

REVOKE ALL ON FUNCTION public.fn_chat_messages_delivered_guard() FROM PUBLIC, anon, authenticated;
