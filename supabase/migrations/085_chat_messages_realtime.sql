-- =============================================================================
-- Migration 085: chat_messages realtime — THE fix for "messages only appear
-- after leaving and reopening the chat"
-- =============================================================================
-- ROOT CAUSE
-- `public.chat_messages` was never added to the `supabase_realtime` publication.
-- Migration 008 (2023) left it as a manual Dashboard step in a comment
-- ("Database > Replication > add chat_messages to publication") and that step
-- was never completed. Migration 040 added notifications/applications, 050
-- added the dispute tables, 083 added chats — chat_messages was missed every
-- time. That is why the conversation LIST updates live (chats is published)
-- while the message THREAD does not (chat_messages is not).
--
-- Client symptom: watchMessages() binds INSERT + UPDATE on chat_messages; the
-- server rejects bindings for an unpublished table, the channel goes to
-- RealtimeSubscribeStatus.channelError, and — because one failed binding fails
-- the WHOLE channel — no INSERT events arrive either. Observed on device:
--   watchMessages channel status: channelError error: Exception: Unable to
--   subscribe to changes with given parameters. Please check Realtime is
--   enabled for the given connect parameters: [event: UPDATE, schema: public,
--   table: chat_messages, filters: [{"chat_id","eq",...}]]
-- The thread then only ever populates from the REST fetch on screen open,
-- which is exactly the "leave and reopen to see it" behaviour.
--
-- WHAT THIS DOES
-- 1. Adds public.chat_messages to the supabase_realtime publication.
-- 2. Sets REPLICA IDENTITY FULL so UPDATE events carry the full row. Without
--    it Postgres only ships the primary key in the old record, and Realtime
--    cannot evaluate the chat_id filter on UPDATE — which the app needs for
--    live journey position updates, arrival receipts, seen receipts and soft
--    deletes (all are UPDATEs to an existing row, not INSERTs).
--
-- RLS is unchanged. Realtime still authorises every subscriber against the
-- existing SELECT policies using the caller's JWT, so a user only receives
-- events for chats they can already read. This grants no new data access.
--
-- SAFE + IDEMPOTENT. Matches the guarded pattern of 040/050/083.
-- Rollback:
--   ALTER PUBLICATION supabase_realtime DROP TABLE public.chat_messages;
--   ALTER TABLE public.chat_messages REPLICA IDENTITY DEFAULT;
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'chat_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages;
  END IF;
END $$;

-- Full row on UPDATE so filtered UPDATE subscriptions work (journey updates,
-- arrival, seen receipts, soft delete). Cheap for this table: rows are small
-- and updates are low-volume relative to inserts.
ALTER TABLE public.chat_messages REPLICA IDENTITY FULL;

-- Verification (expect one row, and relreplident = 'f'):
--   SELECT tablename FROM pg_publication_tables
--    WHERE pubname='supabase_realtime' AND tablename='chat_messages';
--   SELECT relreplident FROM pg_class WHERE oid='public.chat_messages'::regclass;
