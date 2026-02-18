-- =============================================================================
-- Run in Supabase SQL Editor if you get: "Could not find 'phone_number' column"
-- =============================================================================
-- Adds missing columns to public.users so app sync and JOINs work.
-- Safe to run multiple times (IF NOT EXISTS).
-- =============================================================================

ALTER TABLE public.users ADD COLUMN IF NOT EXISTS phone_number text;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS profile_image text;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS avatar_url text;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS last_login timestamptz;

-- Refresh schema cache (Supabase may need a moment; or restart API)
-- After running, user sync and post creation should work.
