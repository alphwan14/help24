-- =============================================================================
-- Chat messages: schema audit, RLS for participants/sender-only, notification-ready.
-- Notifications fire via Database Webhook (Dashboard) or trigger; Edge Function
-- uses service_role to bypass RLS when reading chats/users.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. SCHEMA: Ensure chat_messages has all required columns
-- -----------------------------------------------------------------------------
-- (id, chat_id, sender_id, content, created_at, type already from 008)
-- (attachment_url from 013)
ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS attachment_url text;
COMMENT ON COLUMN public.chat_messages.attachment_url IS 'Optional URL for image/file attachments.';

-- Ensure defaults and not-null where intended
ALTER TABLE public.chat_messages
  ALTER COLUMN content SET DEFAULT '',
  ALTER COLUMN type SET DEFAULT 'text';

-- -----------------------------------------------------------------------------
-- 2. RLS: Only chat participants can read; only sender can insert their message
-- -----------------------------------------------------------------------------
ALTER TABLE public.chats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

-- Chats: select/insert/update only for participants (user1 or user2 = current user)
DROP POLICY IF EXISTS "chats_select" ON public.chats;
CREATE POLICY "chats_select" ON public.chats
  FOR SELECT TO authenticated
  USING (
    user1 = (auth.jwt()->>'user_id') OR user2 = (auth.jwt()->>'user_id')
  );

DROP POLICY IF EXISTS "chats_insert" ON public.chats;
CREATE POLICY "chats_insert" ON public.chats
  FOR INSERT TO authenticated
  WITH CHECK (
    user1 = (auth.jwt()->>'user_id') OR user2 = (auth.jwt()->>'user_id')
  );

DROP POLICY IF EXISTS "chats_update" ON public.chats;
CREATE POLICY "chats_update" ON public.chats
  FOR UPDATE TO authenticated
  USING (
    user1 = (auth.jwt()->>'user_id') OR user2 = (auth.jwt()->>'user_id')
  )
  WITH CHECK (
    user1 = (auth.jwt()->>'user_id') OR user2 = (auth.jwt()->>'user_id')
  );

-- Chat messages: only participants can read; only sender can insert (and must be participant)
DROP POLICY IF EXISTS "chat_messages_select" ON public.chat_messages;
CREATE POLICY "chat_messages_select" ON public.chat_messages
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.chats c
      WHERE c.id = chat_messages.chat_id
        AND (c.user1 = (auth.jwt()->>'user_id') OR c.user2 = (auth.jwt()->>'user_id'))
    )
  );

DROP POLICY IF EXISTS "chat_messages_insert" ON public.chat_messages;
CREATE POLICY "chat_messages_insert" ON public.chat_messages
  FOR INSERT TO authenticated
  WITH CHECK (
    sender_id = (auth.jwt()->>'user_id')
    AND EXISTS (
      SELECT 1 FROM public.chats c
      WHERE c.id = chat_messages.chat_id
        AND (c.user1 = (auth.jwt()->>'user_id') OR c.user2 = (auth.jwt()->>'user_id'))
    )
  );

DROP POLICY IF EXISTS "chat_messages_update" ON public.chat_messages;
CREATE POLICY "chat_messages_update" ON public.chat_messages
  FOR UPDATE TO authenticated
  USING (
    sender_id = (auth.jwt()->>'user_id')
    AND EXISTS (
      SELECT 1 FROM public.chats c
      WHERE c.id = chat_messages.chat_id
        AND (c.user1 = (auth.jwt()->>'user_id') OR c.user2 = (auth.jwt()->>'user_id'))
    )
  )
  WITH CHECK (sender_id = (auth.jwt()->>'user_id'));

-- Grant (RLS still applies)
GRANT SELECT, INSERT, UPDATE ON public.chats TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.chat_messages TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. NOTIFICATIONS: Database Webhook (configure in Dashboard)
-- -----------------------------------------------------------------------------
-- To trigger the Edge Function on every new message:
-- 1. Dashboard > Database > Webhooks > Create a new webhook
-- 2. Table: public.chat_messages
-- 3. Events: Insert
-- 4. Type: Supabase Edge Functions
-- 5. Function: send-chat-push
-- 6. HTTP method: POST
--
-- The webhook runs after the insert commits; it is not subject to RLS.
-- The Edge Function uses SUPABASE_SERVICE_ROLE_KEY to read chats and users,
-- so it bypasses RLS and always sees the correct recipient and FCM tokens.

COMMENT ON TABLE public.chat_messages IS 'Messages per chat. Columns: id, chat_id, sender_id, content, created_at, type, attachment_url, latitude, longitude, live_until. Notifications via Database Webhook → send-chat-push.';
