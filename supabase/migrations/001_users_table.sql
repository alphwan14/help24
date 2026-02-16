-- =============================================================================
-- RUN THIS IN SUPABASE SQL EDITOR
-- =============================================================================
-- Firebase → Supabase user sync: users table
-- Safe to re-run: IF NOT EXISTS for table; policies dropped then recreated.
-- Primary key = Firebase UID (text). created_at has default.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.users (
  id text NOT NULL,
  phone_number text,
  email text,
  name text DEFAULT ''::text,
  profile_image text,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_login timestamptz,
  CONSTRAINT users_pkey PRIMARY KEY (id)
);

-- If table already existed with photo_url, add profile_image for sync
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS profile_image text;

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- Re-run safe: drop then create
DROP POLICY IF EXISTS "Users are viewable by anon and authenticated" ON public.users;
CREATE POLICY "Users are viewable by anon and authenticated"
  ON public.users FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "Users insert by anon and authenticated" ON public.users;
CREATE POLICY "Users insert by anon and authenticated"
  ON public.users FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

DROP POLICY IF EXISTS "Users update by anon and authenticated" ON public.users;
CREATE POLICY "Users update by anon and authenticated"
  ON public.users FOR UPDATE
  TO anon, authenticated
  USING (true)
  WITH CHECK (true);

COMMENT ON TABLE public.users IS 'Synced from Firebase Auth (uid, phone, email). id = Firebase UID.';
