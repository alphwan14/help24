-- Migration 044: remove dead chat-notification machinery from the database.
--
-- Background: migration 016 added an AFTER INSERT trigger on chat_messages
-- (message_notification_trigger → queue_notification_on_message) that writes a
-- row into public.notification_queue. NOTHING in the codebase ever consumes
-- notification_queue, so the trigger is pure dead weight. We remove it (and the
-- table + function) so the ONLY chat-notification path is:
--
--   Flutter sendMessage → POST /notifications/chat-message (NestJS) → FCM data-only
--
-- This guarantees the database itself emits no notifications and cannot be a
-- second/duplicate FCM source.
--
-- NOTE: the duplicate "Someone" push was NOT caused by this trigger (it sends no
-- HTTP/FCM — it only inserts a row). The real foreign emitter is the legacy
-- Supabase Edge Function `send-chat-push`, which must be UNDEPLOYED in the
-- dashboard (it lives in the cloud, not in migrations). See the function's
-- header comment. This migration is cleanup + hardening, not the primary fix.

DROP TRIGGER  IF EXISTS message_notification_trigger ON public.chat_messages;
DROP FUNCTION IF EXISTS public.queue_notification_on_message();
DROP TABLE    IF EXISTS public.notification_queue;
