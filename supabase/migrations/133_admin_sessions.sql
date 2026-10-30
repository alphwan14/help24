-- =============================================================================
-- Migration 133: one console key per sign-in, not one per admin
-- =============================================================================
-- ADDITIVE. One new table, nothing written at apply time.
--
-- The console's backend key (the arbitration bearer in the dashboard's
-- h24_admin_token cookie) lived in admin_users.token_hash — ONE per admin.
-- Every restore minted a new key and overwrote the hash, so an admin with the
-- console open on a phone and a laptop had each device retire the other's
-- key. The device left holding the old key got 401 "Invalid admin token." on
-- every call until a full reload (seen live 2026-10-30: a restore at 19:41:12,
-- then every /admin/identity/people search from the other device refused —
-- the Invite an admin picker).
--
-- Now each restore adds a row here instead, so keys held by different devices
-- stand side by side. A key is still only as good as its admin: the backend
-- re-reads admin_users (active, role) on every request, exactly as before,
-- so disabling an admin or changing their role takes effect at once.
-- A key also expires after 12 hours — the dashboard cookie's lifetime — which
-- the old column never did; the dashboard renews it from the Supabase session.
--
-- Deploy order is free: the backend falls back to the old single-key
-- behaviour while this table does not exist.
--
-- Service role only (the backend). No policies: anon/authenticated get nothing.
--
-- Rollback: DROP TABLE IF EXISTS public.admin_sessions;
--           (every device then restores once, on the old single key)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.admin_sessions (
  -- SHA-256 hex of the bearer. Never the plaintext.
  token_hash  text        PRIMARY KEY CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  admin_id    uuid        NOT NULL REFERENCES public.admin_users (id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_admin_sessions_admin   ON public.admin_sessions (admin_id);
CREATE INDEX IF NOT EXISTS idx_admin_sessions_expires ON public.admin_sessions (expires_at);

ALTER TABLE public.admin_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.admin_sessions FROM anon, authenticated;

COMMENT ON TABLE public.admin_sessions IS
  'Console backend keys, one per sign-in (migration 133). Hash only; 12 h lifetime; validity also requires admin_users.active.';
