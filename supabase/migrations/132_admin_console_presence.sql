-- =============================================================================
-- Migration 132: when each admin was last in the console
-- =============================================================================
-- ADDITIVE. One nullable column; nothing written at apply time.
--
-- Admin Roles showed "Last active" from admin_users.last_login_at — which the
-- backend stamps when it mints an arbitration token, not when anyone uses the
-- console. An admin working all afternoon on one token looked inactive; there
-- was no way to tell who is in the console right now.
--
-- The dashboard now sends a heartbeat once a minute while a console tab is
-- open and visible (components/ConsolePresence.tsx → /api/admin/presence),
-- and writes it here at most once a minute per admin. "In the console now"
-- means a heartbeat in the last 150 seconds — the same freshness rule as a
-- member's "Online now" (admin-dashboard/lib/activity.ts).
--
-- Rollback: ALTER TABLE public.admin_users DROP COLUMN IF EXISTS last_seen_at;
-- =============================================================================

ALTER TABLE public.admin_users ADD COLUMN IF NOT EXISTS last_seen_at timestamptz;

COMMENT ON COLUMN public.admin_users.last_seen_at IS
  'Last console heartbeat (once a minute while a dashboard tab is open and visible). NULL = not seen since 132.';
