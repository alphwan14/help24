-- =============================================================================
-- Relax RLS for chats and chat_messages so the app works without custom JWT.
-- The exchange-firebase-token Edge Function can fail in browser (CORS / Failed to fetch),
-- so auth.jwt()->>'user_id' is never set and strict policies block all access.
-- This migration restores permissive policies for anon + authenticated so
-- "Contact Provider" and messaging work with the anon key only.
-- Re-tighten later (e.g. re-apply auth.jwt()->>'user_id' policies) once the
-- token exchange is reliable (e.g. CORS fixed or app running on mobile).
-- =============================================================================

-- ----- CHATS: allow anon and authenticated to read/write (no JWT required) -----
DROP POLICY IF EXISTS "chats_select" ON public.chats;
CREATE POLICY "chats_select" ON public.chats
  FOR SELECT TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "chats_insert" ON public.chats;
CREATE POLICY "chats_insert" ON public.chats
  FOR INSERT TO anon, authenticated
  WITH CHECK (true);

DROP POLICY IF EXISTS "chats_update" ON public.chats;
CREATE POLICY "chats_update" ON public.chats
  FOR UPDATE TO anon, authenticated
  USING (true)
  WITH CHECK (true);

-- ----- CHAT_MESSAGES: allow anon and authenticated to read/write -----
DROP POLICY IF EXISTS "chat_messages_select" ON public.chat_messages;
CREATE POLICY "chat_messages_select" ON public.chat_messages
  FOR SELECT TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "chat_messages_insert" ON public.chat_messages;
CREATE POLICY "chat_messages_insert" ON public.chat_messages
  FOR INSERT TO anon, authenticated
  WITH CHECK (true);

DROP POLICY IF EXISTS "chat_messages_update" ON public.chat_messages;
CREATE POLICY "chat_messages_update" ON public.chat_messages
  FOR UPDATE TO anon, authenticated
  USING (true)
  WITH CHECK (true);

-- Ensure anon can access these tables (014 only granted to authenticated)
GRANT SELECT, INSERT, UPDATE ON public.chats TO anon;
GRANT SELECT, INSERT, UPDATE ON public.chat_messages TO anon;

COMMENT ON POLICY "chats_select" ON public.chats IS 'Relaxed: allow anon/authenticated read. Tighten with auth.jwt()->>''user_id'' when token exchange works.';
COMMENT ON POLICY "chats_insert" ON public.chats IS 'Relaxed: allow anon/authenticated insert. Tighten when token exchange works.';
COMMENT ON POLICY "chat_messages_select" ON public.chat_messages IS 'Relaxed: allow anon/authenticated read. Tighten when token exchange works.';
COMMENT ON POLICY "chat_messages_insert" ON public.chat_messages IS 'Relaxed: allow anon/authenticated insert. Tighten when token exchange works.';
