-- =============================================================================
-- RLS: chats, chat_messages, users (profiles), storage (profiles bucket).
-- Uses auth.jwt()->>'user_id' (Firebase UID set by app via custom JWT session).
-- App must call setSession with a JWT containing user_id after Firebase login.
-- =============================================================================

-- Helper: current user id from JWT (Firebase UID). Null when not authenticated.
-- CREATE OR REPLACE FUNCTION public.current_user_id() RETURNS text AS $$
--   SELECT COALESCE(auth.jwt()->>'user_id', '')::text;
-- $$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ----- CHATS -----
DROP POLICY IF EXISTS "chats_select" ON public.chats;
CREATE POLICY "chats_select" ON public.chats FOR SELECT TO authenticated
  USING (
    user1 = (auth.jwt()->>'user_id') OR user2 = (auth.jwt()->>'user_id')
  );

DROP POLICY IF EXISTS "chats_insert" ON public.chats;
CREATE POLICY "chats_insert" ON public.chats FOR INSERT TO authenticated
  WITH CHECK (
    user1 = (auth.jwt()->>'user_id') OR user2 = (auth.jwt()->>'user_id')
  );

DROP POLICY IF EXISTS "chats_update" ON public.chats;
CREATE POLICY "chats_update" ON public.chats FOR UPDATE TO authenticated
  USING (
    user1 = (auth.jwt()->>'user_id') OR user2 = (auth.jwt()->>'user_id')
  )
  WITH CHECK (
    user1 = (auth.jwt()->>'user_id') OR user2 = (auth.jwt()->>'user_id')
  );

-- Allow anon to retain ability to create session (no SELECT/INSERT/UPDATE for anon on chats)
-- So anon cannot read/write chats. Authenticated only.

-- ----- CHAT_MESSAGES -----
DROP POLICY IF EXISTS "chat_messages_select" ON public.chat_messages;
CREATE POLICY "chat_messages_select" ON public.chat_messages FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.chats c
      WHERE c.id = chat_messages.chat_id
        AND (c.user1 = (auth.jwt()->>'user_id') OR c.user2 = (auth.jwt()->>'user_id'))
    )
  );

DROP POLICY IF EXISTS "chat_messages_insert" ON public.chat_messages;
CREATE POLICY "chat_messages_insert" ON public.chat_messages FOR INSERT TO authenticated
  WITH CHECK (
    sender_id = (auth.jwt()->>'user_id')
    AND EXISTS (
      SELECT 1 FROM public.chats c
      WHERE c.id = chat_messages.chat_id
        AND (c.user1 = (auth.jwt()->>'user_id') OR c.user2 = (auth.jwt()->>'user_id'))
    )
  );

DROP POLICY IF EXISTS "chat_messages_update" ON public.chat_messages;
CREATE POLICY "chat_messages_update" ON public.chat_messages FOR UPDATE TO authenticated
  USING (
    sender_id = (auth.jwt()->>'user_id')
    AND EXISTS (
      SELECT 1 FROM public.chats c
      WHERE c.id = chat_messages.chat_id
        AND (c.user1 = (auth.jwt()->>'user_id') OR c.user2 = (auth.jwt()->>'user_id'))
    )
  )
  WITH CHECK (
    sender_id = (auth.jwt()->>'user_id')
  );

-- ----- USERS (profiles) -----
-- SELECT: allow all (anon + authenticated) to read profiles for display (names, avatars).
DROP POLICY IF EXISTS "Users are viewable by anon and authenticated" ON public.users;
CREATE POLICY "users_select" ON public.users FOR SELECT TO anon, authenticated
  USING (true);

-- INSERT: only own row (e.g. on first sign-up sync).
DROP POLICY IF EXISTS "Users insert by anon and authenticated" ON public.users;
CREATE POLICY "users_insert_own" ON public.users FOR INSERT TO authenticated
  WITH CHECK (id = (auth.jwt()->>'user_id'));
-- Allow anon to insert for sign-up flow (e.g. guest or first-time sync before session set).
DROP POLICY IF EXISTS "users_insert_anon" ON public.users;
CREATE POLICY "users_insert_anon" ON public.users FOR INSERT TO anon
  WITH CHECK (true);

-- UPDATE: only own profile.
DROP POLICY IF EXISTS "Users update by anon and authenticated" ON public.users;
CREATE POLICY "users_update_own" ON public.users FOR UPDATE TO authenticated
  USING (id = (auth.jwt()->>'user_id'))
  WITH CHECK (id = (auth.jwt()->>'user_id'));

-- ----- STORAGE (profiles bucket) -----
-- Read: allow all (public bucket for profile images).
DROP POLICY IF EXISTS "profiles_read" ON storage.objects;
CREATE POLICY "profiles_read" ON storage.objects FOR SELECT TO anon, authenticated
  USING (bucket_id = 'profiles');

-- Insert: only into own folder (path = user_id/...).
DROP POLICY IF EXISTS "profiles_upload" ON storage.objects;
CREATE POLICY "profiles_upload" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'profiles'
    AND (storage.foldername(name))[1] = (auth.jwt()->>'user_id')
  );

-- Update: only own files.
DROP POLICY IF EXISTS "profiles_update" ON storage.objects;
CREATE POLICY "profiles_update" ON storage.objects FOR UPDATE TO authenticated
  USING (
    bucket_id = 'profiles'
    AND (storage.foldername(name))[1] = (auth.jwt()->>'user_id')
  )
  WITH CHECK (
    bucket_id = 'profiles'
    AND (storage.foldername(name))[1] = (auth.jwt()->>'user_id')
  );

COMMENT ON POLICY "chats_select" ON public.chats IS 'Users see only chats where they are user1 or user2.';
COMMENT ON POLICY "chat_messages_select" ON public.chat_messages IS 'Users see only messages in chats they belong to.';
COMMENT ON POLICY "users_update_own" ON public.users IS 'Users can update only their own profile row.';
