-- =============================================================================
-- Migration 083: add chats to the supabase_realtime publication
-- =============================================================================
-- The Messages tab now subscribes to postgres_changes on public.chats
-- (filtered per column: user1 = <uid> OR user2 = <uid> as two bindings) so the
-- conversation list refreshes the moment a chat row changes — new message
-- bumps last_message/updated_at/unread counts — instead of waiting for the
-- 15s poll. Once the client sees the first realtime event it stretches its
-- fallback poll to 60s, cutting steady-state chat-list traffic by ~4x.
--
-- Safe to apply any time: until this runs, the channel simply never fires and
-- the app keeps the legacy 15s poll behavior. Idempotent (matches 040/050).
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'chats'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chats;
  END IF;
END $$;
