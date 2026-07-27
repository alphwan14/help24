-- =============================================================================
-- Migration 093 — trust flags, availability, and multi-skill professions
-- =============================================================================
-- Three ranking signals in the recommendation spec have no column to read:
--
--   #7  Availability  — "if a provider marked themselves Available now, boost"
--   #14 Trust signals — "verified providers, businesses, top-rated professionals"
--   #3  Skills        — "later users may have multiple skills … design today's
--                        architecture for that future"
--
-- This migration creates all three. Defaults are chosen so that applying it
-- changes NOTHING about today's ranking: every user is unverified, individual,
-- and has no explicit availability, which the engine scores as *neutral* — not
-- as a penalty. Trust only starts differentiating once verification actually
-- begins.
--
-- ON SKILLS BEING A TABLE RATHER THAN AN ARRAY
-- --------------------------------------------
-- `users.profession` stays exactly as it is: one canonical primary trade
-- (086/089). Secondary skills go in their own table because they carry a
-- per-skill weight and will later carry evidence (verified-by-review, years,
-- certificate). An array column would have to be rewritten the first time a
-- skill needed a second attribute. The table ships EMPTY, so the `skills`
-- signal returns "not applicable" for every existing user and contributes
-- nothing until users start filling it in.
--
-- SAFE + ADDITIVE. Rollback:
--   DROP TABLE public.user_skills;
--   ALTER TABLE public.users
--     DROP COLUMN IF EXISTS is_verified,
--     DROP COLUMN IF EXISTS account_type,
--     DROP COLUMN IF EXISTS available_until;
-- =============================================================================

-- ── Trust ────────────────────────────────────────────────────────────────────
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS is_verified   BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS account_type  TEXT    NOT NULL DEFAULT 'individual';

-- Constraint added separately + guarded, so re-running never fails on an
-- existing constraint and legacy rows (all defaulted) always satisfy it.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'users_account_type_check'
  ) THEN
    ALTER TABLE public.users ADD CONSTRAINT users_account_type_check
      CHECK (account_type IN ('individual', 'business'));
  END IF;
END $$;

-- ── Availability ─────────────────────────────────────────────────────────────
-- A timestamp, not a boolean. "Available now" that a provider set on Tuesday
-- and forgot about is a lie by Friday, and a lie the ranking engine would
-- amplify. An availability WINDOW expires on its own.
--
-- NULL = "hasn't said" = neutral. The engine then falls back to last_active_at.
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS available_until TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_users_available_until
  ON public.users (available_until)
  WHERE available_until IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_users_profession
  ON public.users (profession)
  WHERE profession IS NOT NULL AND profession <> '';

COMMENT ON COLUMN public.users.is_verified IS
  'Identity/credential verified by Help24. Ranking signal 14 (trust). '
  'Server-set only — never writable by the account itself.';
COMMENT ON COLUMN public.users.account_type IS
  'individual | business. Ranking signal 14 (trust).';
COMMENT ON COLUMN public.users.available_until IS
  'Provider is "available now" until this instant. NULL = unstated (neutral). '
  'A window rather than a flag so stale availability expires by itself.';

-- ── Multi-skill ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_skills (
  user_id       TEXT        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  profession_id TEXT        NOT NULL,   -- professions.id (086/089)
  -- 0..1 self-declared proficiency; the ranking engine multiplies the match by
  -- it, so a weak secondary skill never outranks a primary profession.
  weight        DOUBLE PRECISION NOT NULL DEFAULT 0.7
                  CHECK (weight >= 0 AND weight <= 1),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, profession_id)
);

-- No FK to professions, for the same reason 086 gives for users.profession:
-- a catalogue edit must never fail an unrelated write. Validity is enforced at
-- the write path (the app only ever writes ids from the registry).

CREATE INDEX IF NOT EXISTS idx_user_skills_user
  ON public.user_skills (user_id);

ALTER TABLE public.user_skills ENABLE ROW LEVEL SECURITY;

-- Owner-scoped writes, public reads: a provider's skills are shown on their
-- profile, exactly like users.profession.
DROP POLICY IF EXISTS user_skills_read ON public.user_skills;
CREATE POLICY user_skills_read ON public.user_skills
  FOR SELECT TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS user_skills_owner_write ON public.user_skills;
CREATE POLICY user_skills_owner_write ON public.user_skills
  FOR ALL TO authenticated
  USING      (user_id = (auth.jwt() ->> 'user_id'))
  WITH CHECK (user_id = (auth.jwt() ->> 'user_id'));

DROP POLICY IF EXISTS user_skills_service_role ON public.user_skills;
CREATE POLICY user_skills_service_role ON public.user_skills
  TO service_role
  USING (true) WITH CHECK (true);

GRANT SELECT ON public.user_skills TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_skills TO authenticated;
GRANT ALL ON public.user_skills TO service_role;

COMMENT ON TABLE public.user_skills IS
  'Secondary professions a user can serve, beyond users.profession. Ranking '
  'signal 3. Ships empty: the signal reports "not applicable" until rows exist, '
  'so no existing user is affected.';
