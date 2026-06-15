-- =============================================================================
-- Migration 053: admin_invites lifecycle — Stripe-style "consume on success"
-- =============================================================================
-- Problem: invites were flipped to a terminal state (accepted) BEFORE
-- provisioning, so any partial failure permanently consumed the token and a
-- retry got a false "already used". An opened/refreshed link could also burn it.
--
-- New state machine (token is consumed ONLY on full success):
--
--   pending    → freshly issued, never opened
--   validated  → link opened & token verified (GET) — NON-consuming
--   completed  → onboarding fully succeeded (auth user + password + role +
--                admin_users + bearer). TERMINAL. Reuse → 410.
--   expired    → past expires_at or revoked. TERMINAL.
--
-- "Active" (an outstanding invite for an email) = pending OR validated.
-- =============================================================================

-- 1. Allow the new states. Migrate the legacy 'accepted' → 'completed' first so
--    the tightened CHECK doesn't reject existing rows.
ALTER TABLE public.admin_invites
  DROP CONSTRAINT IF EXISTS admin_invites_status_check;

UPDATE public.admin_invites SET status = 'completed' WHERE status = 'accepted';

ALTER TABLE public.admin_invites
  ADD CONSTRAINT admin_invites_status_check
  CHECK (status IN ('pending', 'validated', 'completed', 'expired'));

-- 2. "One active invite per email" must now span pending AND validated, so a
--    half-finished (opened-but-not-completed) invite still blocks duplicates.
DROP INDEX IF EXISTS uniq_admin_invites_pending_email;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_admin_invites_active_email
  ON public.admin_invites (lower(email))
  WHERE status IN ('pending', 'validated');

NOTIFY pgrst, 'reload schema';
