-- =============================================================================
-- Migration 142: "Message Help24" in the app
-- =============================================================================
-- ADDITIVE. Columns and one index on the Inbox tables (migration 138); no rows
-- change, nothing is dropped.
--
-- Members can now write to Help24 from the app (Profile → Support → Message
-- Help24), not only by email. Each member has ONE ongoing conversation in the
-- app, like a chat with Help24; staff answer it from the same dashboard Inbox,
-- and the answer arrives in the app with a notification instead of an email.
--
--   support_conversations.reply_via   'email' (as before) or 'app': where
--                                     Help24's answers go.
--   support_conversations.member_read_at
--                                     when the member last opened the thread
--                                     in the app: "Seen" in the dashboard, and
--                                     the unread count in the app.
--   support_conversations.contact_email
--                                     may now be empty for an app thread: a
--                                     member who signed up by phone has none.
--   support_messages.client_id        the app's id for a message it sent, so a
--                                     retried send is stored once.
--
-- Service role only, as before: the app reaches these tables through the
-- backend (/support/app/*), never directly.
--
-- Rollback (only while no app threads exist):
--   DROP INDEX IF EXISTS public.uniq_support_app_thread;
--   ALTER TABLE public.support_messages DROP COLUMN IF EXISTS client_id;
--   ALTER TABLE public.support_conversations DROP COLUMN IF EXISTS member_read_at;
--   ALTER TABLE public.support_conversations DROP COLUMN IF EXISTS reply_via;
--   ALTER TABLE public.support_conversations ALTER COLUMN contact_email SET NOT NULL;
-- =============================================================================

ALTER TABLE public.support_conversations
  ADD COLUMN IF NOT EXISTS reply_via text NOT NULL DEFAULT 'email' CHECK (reply_via IN ('email', 'app')),
  ADD COLUMN IF NOT EXISTS member_read_at timestamptz;

-- The format check from 138 still applies whenever an address is present.
ALTER TABLE public.support_conversations ALTER COLUMN contact_email DROP NOT NULL;

-- One ongoing app conversation per member.
CREATE UNIQUE INDEX IF NOT EXISTS uniq_support_app_thread
  ON public.support_conversations (user_id) WHERE reply_via = 'app' AND user_id IS NOT NULL;

ALTER TABLE public.support_messages
  ADD COLUMN IF NOT EXISTS client_id uuid UNIQUE;

COMMENT ON COLUMN public.support_conversations.reply_via IS
  'Where Help24''s answers go: email (support@ threads) or app (Message Help24, migration 142).';
COMMENT ON COLUMN public.support_messages.client_id IS
  'The app''s id for a message it sent; a retried send is stored once (migration 142).';
