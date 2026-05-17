-- =============================================================================
-- Migration 028: Cleanup empty chat rows
-- =============================================================================
-- Removes chat rows that have no messages in chat_messages.
-- These were created prematurely (before any message was sent) by the old
-- "contact provider" / "offer help" / "accept application" flows.
--
-- Safe: uses a sub-select to check for the existence of a related message row.
-- Rows with at least one message in chat_messages are NOT touched.
-- =============================================================================

DELETE FROM public.chats
WHERE NOT EXISTS (
  SELECT 1
  FROM public.chat_messages cm
  WHERE cm.chat_id = chats.id
);

-- Verify: these should both return 0 after migration.
-- SELECT COUNT(*) FROM public.chats WHERE last_message = '' OR last_message IS NULL;
-- SELECT COUNT(*) FROM public.chats c WHERE NOT EXISTS (SELECT 1 FROM public.chat_messages cm WHERE cm.chat_id = c.id);
