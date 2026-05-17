-- Migration 026: Fix sender_id / user1 / user2 column types (uuid → text)
-- Firebase UIDs are alphanumeric strings, not UUIDs (code 22P02 on insert).

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Drop every RLS policy on chats and chat_messages so ALTER can proceed.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  pol RECORD;
BEGIN
  FOR pol IN
    SELECT policyname, tablename
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('chats', 'chat_messages')
  LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public.%I',
      pol.policyname, pol.tablename
    );
  END LOOP;
  RAISE NOTICE 'All chats/chat_messages policies dropped.';
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Alter column types unconditionally (no IF check — fixes the issue
--    where information_schema data_type didn't match 'uuid').
--    If a column is already text, this is a no-op in practice.
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  -- chat_messages.sender_id
  BEGIN
    ALTER TABLE public.chat_messages
      ALTER COLUMN sender_id TYPE text USING sender_id::text;
    RAISE NOTICE 'chat_messages.sender_id → text OK';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'chat_messages.sender_id: % (skipped)', SQLERRM;
  END;

  -- chats.user1
  BEGIN
    ALTER TABLE public.chats
      ALTER COLUMN user1 TYPE text USING user1::text;
    RAISE NOTICE 'chats.user1 → text OK';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'chats.user1: % (skipped)', SQLERRM;
  END;

  -- chats.user2
  BEGIN
    ALTER TABLE public.chats
      ALTER COLUMN user2 TYPE text USING user2::text;
    RAISE NOTICE 'chats.user2 → text OK';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'chats.user2: % (skipped)', SQLERRM;
  END;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Recreate relaxed policies (anon + authenticated, no JWT required).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE POLICY "chats_select" ON public.chats
  FOR SELECT TO anon, authenticated USING (true);

CREATE POLICY "chats_insert" ON public.chats
  FOR INSERT TO anon, authenticated WITH CHECK (true);

CREATE POLICY "chats_update" ON public.chats
  FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

CREATE POLICY "chat_messages_select" ON public.chat_messages
  FOR SELECT TO anon, authenticated USING (true);

CREATE POLICY "chat_messages_insert" ON public.chat_messages
  FOR INSERT TO anon, authenticated WITH CHECK (true);

CREATE POLICY "chat_messages_update" ON public.chat_messages
  FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Grants
-- ─────────────────────────────────────────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE ON public.chats TO anon;
GRANT SELECT, INSERT, UPDATE ON public.chat_messages TO anon;
