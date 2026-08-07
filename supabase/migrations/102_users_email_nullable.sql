-- =============================================================================
-- Migration 102 — a phone-only account is allowed to have no email
-- =============================================================================
-- `public.users.email` was NOT NULL with no default, which left phone-only
-- sign-up with no correct move available:
--
--   write ''          → collides with every other phone-only account on the
--                       unique index (Postgres permits many NULLs, one '')
--   omit the column   → 23502 null value in column "email" violates not-null
--
-- Both end identically: no `users` row, no FK target for
-- `posts.author_user_id`, and every post/application/profile save failing with
-- "We couldn't finish setting up your account". Migration 101 removed the first
-- horn of that dilemma; this removes the second.
--
-- The model this restores is simply the truth: an account authenticated by
-- phone HAS no email address, and a column that cannot represent that forces
-- the client to invent a value. `''` is not an address — it is a lie that the
-- database then enforces uniqueness over.
--
-- Paired with migration 101 (`WHERE email IS NOT NULL AND email <> ''`), any
-- number of accounts may have no address while every real address stays unique,
-- case-insensitively.
--
-- SAFE + REVERSIBLE: dropping NOT NULL cannot fail and changes no existing row
-- (all 15 currently hold a real address).
--
-- Rollback (only valid while no NULLs exist):
--   UPDATE public.users SET email = '' WHERE email IS NULL;   -- see the warning above
--   ALTER TABLE public.users ALTER COLUMN email SET NOT NULL;
-- =============================================================================

ALTER TABLE public.users ALTER COLUMN email DROP NOT NULL;

COMMENT ON COLUMN public.users.email IS
  'The account''s email address, or NULL when it has none (phone-only sign-in). '
  'Never written as an empty string — see migration 101.';
