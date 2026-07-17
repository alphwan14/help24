-- =============================================================================
-- Migration 080: notifications RLS — fix owner policies to use the exchange claim
-- =============================================================================
-- BUG: signed-in users cannot load notifications — the screen shows its
-- "Failed to load notifications." error state and the bell badge stays dead.
--
-- Root cause: the exchange-firebase-token function signs the client JWT with
-- sub = <firebase-uid> (setSubject(uid)) — a 28-char NON-UUID string. The 033
-- policies check `user_id = auth.uid()::TEXT`, and auth.uid() casts the sub
-- claim to uuid, so evaluating the policy RAISES
--   invalid input syntax for type uuid: "<firebase-uid>"
-- which errors the ENTIRE query (not just filters rows). While clients ran as
-- anon (exchange not yet working), 041's permissive anon policies masked this;
-- once the exchange succeeded, requests moved to the authenticated role whose
-- only notifications policies are the exploding ones — so every SELECT/UPDATE
-- fails outright, and RLS-gated realtime INSERT events for the bell badge are
-- blocked the same way.
--
-- Fix: re-create the owner policies on the app-wide convention used by 061
-- (chats/fcm_tokens/etc.): auth.jwt() ->> 'user_id' (plain text, no uuid
-- cast). Also drop the stale 039-era `fcm_tokens_owner` policy — the same
-- auth.uid() bug class sitting OR'd beside 061's correct
-- `fcm_tokens_owner_all`, where its evaluation can explode fcm_tokens
-- operations (push-token registration) for authenticated users too.
--
-- The 041 anon policies are deliberately UNTOUCHED: requests that arrive
-- before the token exchange completes still read the user's own rows.
--
-- Reversible: re-run the CREATE POLICY blocks from 033 / 039.
-- =============================================================================

-- ── notifications: owner read via the exchange claim ─────────────────────────
DROP POLICY IF EXISTS notifications_owner_read ON public.notifications;
CREATE POLICY notifications_owner_read ON public.notifications
  FOR SELECT TO authenticated
  USING (user_id = (auth.jwt() ->> 'user_id'));

-- ── notifications: owner mark-as-read via the exchange claim ─────────────────
DROP POLICY IF EXISTS notifications_owner_update ON public.notifications;
CREATE POLICY notifications_owner_update ON public.notifications
  FOR UPDATE TO authenticated
  USING      (user_id = (auth.jwt() ->> 'user_id'))
  WITH CHECK (user_id = (auth.jwt() ->> 'user_id'));

-- ── fcm_tokens: remove the stale auth.uid() policy (061's replacement rules) ─
DROP POLICY IF EXISTS fcm_tokens_owner ON public.fcm_tokens;
