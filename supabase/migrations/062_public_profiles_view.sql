-- =============================================================================
-- Migration 062 — S3 (part 2a): public_profiles view (safe author fields)
-- =============================================================================
-- Foundation for locking users PII. Exposes ONLY the non-sensitive fields the
-- (logged-out) feed needs — id, name, avatar, and a has_phone BOOLEAN instead of
-- the raw phone number — so the app can stop reading raw email/phone from users.
--
-- The view runs with the VIEW OWNER's rights (NOT security_invoker), so it can
-- read users even after anon SELECT on the users table is revoked. This is what
-- lets us keep author name/avatar visible to logged-out browsers while the raw
-- users table (email, phone_number) becomes owner-only.
--
-- SAFE + ADDITIVE: this migration only CREATEs a read-only view — it changes no
-- data and revokes nothing. Applying it now is harmless. The users-table lockdown
-- (revoke anon; owner-scoped PII) is a SEPARATE migration (063) to run ONLY after
-- the app has switched its author reads to public_profiles and S1 is verified.
--
-- Rollback: DROP VIEW public.public_profiles;
-- =============================================================================

CREATE OR REPLACE VIEW public.public_profiles AS
SELECT
  id,
  name,
  COALESCE(NULLIF(avatar_url, ''), NULLIF(profile_image, '')) AS avatar_url,
  (phone_number IS NOT NULL AND phone_number <> '')           AS has_phone
FROM public.users;

GRANT SELECT ON public.public_profiles TO anon, authenticated;
