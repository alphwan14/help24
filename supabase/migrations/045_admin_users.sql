-- =============================================================================
-- Migration 045: admin_users — arbitration RBAC identity
-- =============================================================================
-- The backend has no auth layer. The Disputes Centre needs a real admin identity
-- to enforce RBAC (support_agent / senior_admin / super_admin) and to tie every
-- decision to an accountable human (fintech audit requirement).
--
-- Auth model: opaque bearer token. The plaintext token is given to the admin
-- once; only its SHA-256 hash is stored here. The NestJS AdminAuthGuard hashes
-- the incoming `Authorization: Bearer <token>` and looks up the matching row.
--
-- Role hierarchy (ascending privilege):
--   support_agent  → view cases, comment, add evidence, assign, ESCALATE
--   senior_admin   → all of the above + issue financial decisions (payout/refund)
--   super_admin    → all of the above + override assigned cases + manage admins
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- for digest() used by the seed below

CREATE TABLE IF NOT EXISTS public.admin_users (
  id            UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  email         TEXT        NOT NULL UNIQUE,
  name          TEXT        NOT NULL DEFAULT '',
  role          TEXT        NOT NULL DEFAULT 'support_agent'
                            CHECK (role IN ('support_agent','senior_admin','super_admin')),
  -- SHA-256 hex of the bearer token. Never store the plaintext.
  token_hash    TEXT        NOT NULL UNIQUE,
  active         BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_login_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_admin_users_token_hash ON public.admin_users (token_hash);
CREATE INDEX IF NOT EXISTS idx_admin_users_active     ON public.admin_users (active) WHERE active = TRUE;

ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'admin_users_service_role' AND tablename = 'admin_users'
  ) THEN
    -- Only the service role (backend) may read admin identities. Never expose
    -- token hashes to the anon/authenticated client.
    CREATE POLICY admin_users_service_role ON public.admin_users
      USING (true) WITH CHECK (true);
  END IF;
END $$;

GRANT ALL ON public.admin_users TO service_role;

-- ---------------------------------------------------------------------------
-- Seed: bootstrap super_admin.
-- ---------------------------------------------------------------------------
-- ⚠️ DEV BOOTSTRAP TOKEN — ROTATE IMMEDIATELY IN PRODUCTION.
-- Plaintext bearer token below is 'help24-super-admin-CHANGE-ME'. Use it once to
-- create real admins via POST /admin/admins, then DELETE this row (or rotate the
-- token) with:
--   UPDATE public.admin_users
--     SET token_hash = encode(digest('<new-strong-token>','sha256'),'hex')
--     WHERE email = 'founder@help24.app';
INSERT INTO public.admin_users (email, name, role, token_hash)
VALUES (
  'founder@help24.app',
  'Founder (bootstrap)',
  'super_admin',
  encode(digest('help24-super-admin-CHANGE-ME', 'sha256'), 'hex')
)
ON CONFLICT (email) DO NOTHING;
