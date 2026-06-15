-- =============================================================================
-- Migration 052: admin_users integrity + auth self-heal
-- =============================================================================
-- Symptom this addresses: a freshly created admin token returns 401 "Invalid or
-- inactive admin token" on EVERY request, including immediately after creation.
--
-- The NestJS token pipeline is correct (SHA-256 hash on insert, same hash on
-- lookup against token_hash). When auth nonetheless fails for every token, the
-- cause is almost always at the DATA layer, not the code:
--
--   1. admin_users is missing a column the auth SELECT reads (active / name /
--      last_login_at) — schema drift. The SELECT then errors and the old code
--      swallowed it as "invalid token". (The guard now reports this as 503.)
--   2. PostgREST's schema cache is stale after applying 045/051, so
--      .select('active') 404s the column until a reload.
--   3. The backend points at a different Supabase project than where the admin
--      row lives (token hash genuinely not found).
--
-- This migration makes (1) and (2) impossible by ensuring every required column
-- exists and forcing a schema-cache reload. Safe to run repeatedly.
-- =============================================================================

-- Guarantee the table exists (no-op if 045 already created it).
CREATE TABLE IF NOT EXISTS public.admin_users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4()
);

-- Backfill any missing columns the auth path depends on.
ALTER TABLE public.admin_users
  ADD COLUMN IF NOT EXISTS email         TEXT,
  ADD COLUMN IF NOT EXISTS name          TEXT        NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS role          TEXT        NOT NULL DEFAULT 'support_agent',
  ADD COLUMN IF NOT EXISTS token_hash    TEXT,
  ADD COLUMN IF NOT EXISTS active        BOOLEAN     NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ADD COLUMN IF NOT EXISTS last_login_at TIMESTAMPTZ;

-- Any row that predates the `active` column (or was created NULL) must be TRUE
-- to be usable. resolveToken requires active = true exactly.
UPDATE public.admin_users SET active = TRUE WHERE active IS NULL;

-- Ensure the role CHECK + uniqueness constraints exist (idempotent).
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'admin_users_role_check'
  ) THEN
    ALTER TABLE public.admin_users
      ADD CONSTRAINT admin_users_role_check
      CHECK (role IN ('support_agent','senior_admin','super_admin'));
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_admin_users_email      ON public.admin_users (email);
CREATE UNIQUE INDEX IF NOT EXISTS uniq_admin_users_token_hash ON public.admin_users (token_hash);
CREATE INDEX        IF NOT EXISTS idx_admin_users_token_hash  ON public.admin_users (token_hash);

-- Re-assert the bootstrap super_admin so there is always a working token to
-- create/rotate real admins with. Token plaintext: 'help24-super-admin-CHANGE-ME'.
INSERT INTO public.admin_users (email, name, role, token_hash, active)
VALUES (
  'founder@help24.app',
  'Founder (bootstrap)',
  'super_admin',
  encode(digest('help24-super-admin-CHANGE-ME', 'sha256'), 'hex'),
  TRUE
)
ON CONFLICT (email) DO UPDATE
  SET token_hash = EXCLUDED.token_hash,
      role       = 'super_admin',
      active     = TRUE;

-- Force PostgREST (the Supabase REST layer the backend uses) to reload its
-- schema cache, so newly-added columns are immediately queryable.
NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- VERIFY (run these in the SQL editor after applying):
--
--   -- 1. Columns exist?
--   SELECT column_name FROM information_schema.columns
--   WHERE table_schema = 'public' AND table_name = 'admin_users'
--   ORDER BY ordinal_position;
--
--   -- 2. Bootstrap row present, active, correct hash?
--   SELECT email, role, active,
--          token_hash = encode(digest('help24-super-admin-CHANGE-ME','sha256'),'hex')
--            AS bootstrap_hash_matches
--   FROM public.admin_users WHERE email = 'founder@help24.app';
--
--   -- 3. Confirm a specific admin token resolves (paste the RAW token):
--   SELECT email, role, active FROM public.admin_users
--   WHERE token_hash = encode(digest('<paste-raw-token-here>','sha256'),'hex');
-- ---------------------------------------------------------------------------
