-- =============================================================================
-- Migration 139: security@ gets its own place in the Inbox
-- =============================================================================
-- Widens one CHECK: a support conversation's label may now be 'security' as
-- well as 'support' and 'general'. No rows change; nothing else is touched.
--
-- Mail to security@help24.co.ke (replies to account emails, security reports)
-- is filed as 'security', listed only on its own in the dashboard, never mixed
-- with support@ and info@, and answered from security@ as "Help24 Security"
-- (backend support-rules.ts identityFor).
--
-- Apply BEFORE the backend that files security@ mail, so no insert is refused.
--
-- Rollback (only while no 'security' rows exist):
--   ALTER TABLE public.support_conversations DROP CONSTRAINT support_conversations_label_check;
--   ALTER TABLE public.support_conversations ADD CONSTRAINT support_conversations_label_check
--     CHECK (label IN ('support', 'general'));
-- =============================================================================

ALTER TABLE public.support_conversations DROP CONSTRAINT IF EXISTS support_conversations_label_check;
ALTER TABLE public.support_conversations ADD CONSTRAINT support_conversations_label_check
  CHECK (label IN ('support', 'general', 'security'));
