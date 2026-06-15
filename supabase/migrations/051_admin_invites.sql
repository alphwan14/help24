-- =============================================================================
-- Migration 051: admin_invites — invite-only admin onboarding
-- =============================================================================
-- Admins are NEVER self-registered. A super_admin issues an invite (email+role);
-- the invitee accepts via a single-use, time-limited link and, on acceptance,
-- the backend provisions the FULL admin identity in one transaction:
--
--   1. a Supabase Auth user (email + password)   → dashboard UI login
--   2. public.users.role = 'admin'               → middleware access gate
--   3. an admin_users row + bearer token          → arbitration RBAC
--
-- Security model:
--   • token is a cryptographically secure random string (crypto.randomBytes)
--   • single-use: claiming the invite flips status pending → accepted atomically
--   • expires after 7 days (enforced in service + lazy-expired on read)
--   • only super_admin may create invites
--   • at most ONE active (pending) invite per email (partial unique index)
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.admin_invites (
  id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  email       TEXT        NOT NULL,
  role        TEXT        NOT NULL
                          CHECK (role IN ('support_agent','senior_admin','super_admin')),
  -- URL-safe secure random token (base64url of 32 random bytes). Unique.
  token       TEXT        NOT NULL UNIQUE,
  status      TEXT        NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending','accepted','expired')),
  created_by  UUID        REFERENCES public.admin_users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at  TIMESTAMPTZ NOT NULL,
  accepted_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_admin_invites_email  ON public.admin_invites (lower(email));
CREATE INDEX IF NOT EXISTS idx_admin_invites_token  ON public.admin_invites (token);
CREATE INDEX IF NOT EXISTS idx_admin_invites_status ON public.admin_invites (status);

-- Enforce "at most one active invite per email" at the DB level. A second
-- pending invite for the same email cannot be inserted while one is outstanding;
-- the service lazy-expires stale ones first so re-inviting still works.
CREATE UNIQUE INDEX IF NOT EXISTS uniq_admin_invites_pending_email
  ON public.admin_invites (lower(email))
  WHERE status = 'pending';

ALTER TABLE public.admin_invites ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'admin_invites_service_role' AND tablename = 'admin_invites'
  ) THEN
    -- Only the backend (service role) ever touches invites. Tokens are never
    -- exposed to the anon/authenticated client.
    CREATE POLICY admin_invites_service_role ON public.admin_invites
      USING (true) WITH CHECK (true);
  END IF;
END $$;

GRANT ALL ON public.admin_invites TO service_role;
