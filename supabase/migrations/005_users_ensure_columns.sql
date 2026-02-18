-- =============================================================================
-- RUN THIS IN SUPABASE SQL EDITOR
-- =============================================================================
-- Ensure public.users has required columns for app: id, name, email, phone, avatar, created_at.
-- No fake users: all data from Supabase. App syncs on login/signup.
-- =============================================================================

-- Ensure phone column exists (some schemas use phone_number only)
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS phone text;
COMMENT ON COLUMN public.users.phone IS 'Alias/sync for phone_number; prefer phone_number for reads.';

-- Ensure name has default so inserts without name get empty string (app fills from email prefix)
ALTER TABLE public.users ALTER COLUMN name SET DEFAULT '';

-- Ensure avatar_url exists (004 adds it; this is idempotent)
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS avatar_url text;

-- Index for lookups by id (primary key already exists)
-- No further changes needed; RLS from 001 remains.
