-- =============================================================================
-- Migration 061 — S3 (part 1): lock PRIVATE tables to their participants/owner
-- =============================================================================
-- Closes the confirmed exposure where the PUBLIC anon key can read/write every
-- user's private chats, messages and push tokens (USING(true) + GRANT TO anon).
-- After this, only the row's participants (authenticated) can touch them; the
-- backend keeps full access via the service-role key (which bypasses RLS).
--
-- ⚠️ HARD PREREQUISITE — DO NOT APPLY until BOTH are true:
--   1. S1 done: exchange-firebase-token deployed + SUPABASE_JWT_SECRET set, and
--      the app's [AUTH][BRIDGE] result is ok=true (clients run as `authenticated`
--      carrying auth.jwt()->>'user_id'). Applying this while clients are still
--      anon WILL break chat + push tokens for everyone.
--   2. Regression tested: verify chat list, open chat, send message, and push
--      notifications on a device signed in through the working exchange.
--
-- Reversible: re-run the pre-existing GRANT ... TO anon + USING(true) policies.
--
-- NOTE: `users` PII and `posts`/feed are handled separately (part 2) because the
-- app is browsable WITHOUT login, so those tables must keep a narrow anon read
-- (author name/avatar only) — that needs a coordinated feed-query change.
-- =============================================================================

-- The caller's Firebase uid, as embedded by the exchange function:
--   auth.jwt() ->> 'user_id'

-- ── chats: only the two participants ─────────────────────────────────────────
REVOKE ALL ON public.chats FROM anon;
GRANT SELECT, INSERT, UPDATE ON public.chats TO authenticated;
DROP POLICY IF EXISTS chats_select ON public.chats;
DROP POLICY IF EXISTS chats_insert ON public.chats;
DROP POLICY IF EXISTS chats_update ON public.chats;
CREATE POLICY chats_participant ON public.chats
  AS PERMISSIVE FOR ALL TO authenticated
  USING      ((auth.jwt() ->> 'user_id') IN (user1, user2))
  WITH CHECK ((auth.jwt() ->> 'user_id') IN (user1, user2));

-- ── chat_messages: only within a chat you participate in ─────────────────────
REVOKE ALL ON public.chat_messages FROM anon;
GRANT SELECT, INSERT, UPDATE ON public.chat_messages TO authenticated;
DROP POLICY IF EXISTS chat_messages_select ON public.chat_messages;
DROP POLICY IF EXISTS chat_messages_insert ON public.chat_messages;
DROP POLICY IF EXISTS chat_messages_update ON public.chat_messages;
CREATE POLICY chat_messages_participant ON public.chat_messages
  AS PERMISSIVE FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.chats c
    WHERE c.id = chat_messages.chat_id
      AND (auth.jwt() ->> 'user_id') IN (c.user1, c.user2)
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.chats c
    WHERE c.id = chat_messages.chat_id
      AND (auth.jwt() ->> 'user_id') IN (c.user1, c.user2)
  ));

-- ── fcm_tokens: owner only ───────────────────────────────────────────────────
REVOKE ALL ON public.fcm_tokens FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.fcm_tokens TO authenticated;
DROP POLICY IF EXISTS fcm_tokens_owner_all ON public.fcm_tokens;
CREATE POLICY fcm_tokens_owner_all ON public.fcm_tokens
  AS PERMISSIVE FOR ALL TO authenticated
  USING      (user_id = (auth.jwt() ->> 'user_id'))
  WITH CHECK (user_id = (auth.jwt() ->> 'user_id'));

-- ── legacy conversations/messages (still written by the app) ─────────────────
-- Columns: conversations(user1_id, user2_id); messages(sender_user_id, receiver_user_id).
REVOKE ALL ON public.conversations, public.messages FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.conversations, public.messages TO authenticated;
DROP POLICY IF EXISTS "Conversations select by participants" ON public.conversations;
DROP POLICY IF EXISTS "Conversations insert" ON public.conversations;
DROP POLICY IF EXISTS "Conversations update" ON public.conversations;
CREATE POLICY conversations_participant ON public.conversations
  AS PERMISSIVE FOR ALL TO authenticated
  USING      ((auth.jwt() ->> 'user_id') IN (user1_id, user2_id))
  WITH CHECK ((auth.jwt() ->> 'user_id') IN (user1_id, user2_id));
DROP POLICY IF EXISTS "Messages select" ON public.messages;
DROP POLICY IF EXISTS "Messages insert" ON public.messages;
DROP POLICY IF EXISTS "Messages update" ON public.messages;
CREATE POLICY messages_participant ON public.messages
  AS PERMISSIVE FOR ALL TO authenticated
  USING      ((auth.jwt() ->> 'user_id') IN (sender_user_id, receiver_user_id))
  WITH CHECK ((auth.jwt() ->> 'user_id') IN (sender_user_id, receiver_user_id));
