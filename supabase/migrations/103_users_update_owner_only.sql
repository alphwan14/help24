-- =============================================================================
-- Migration 103 — users UPDATE becomes owner-only (closes a payout redirect)
-- =============================================================================
-- WHAT IS OPEN RIGHT NOW
-- ---------------------
-- `public.users` carries TWO permissive UPDATE policies, both unconditional:
--
--   "Users update by anon and authenticated"  {anon,authenticated}  USING true WITH CHECK true
--   users_update                              {public}              USING true
--
-- and `anon` holds table-level UPDATE, DELETE and TRUNCATE grants. RLS policies
-- are OR'd, so either policy alone permits everything.
--
-- The anon key ships inside the Android APK. It is therefore public.
--
-- WHY THIS IS A MONEY BUG, NOT DEFACEMENT
-- ---------------------------------------
-- Migration 098's trigger already refuses `role`, `is_banned`, `is_verified`,
-- `email`, `id` and the reputation columns from a non-service_role caller. It
-- does NOT cover `phone_number` — verified against the live function body.
--
-- And `phone_number` is where provider payouts go. `MpesaService.startPayout`
-- reads it and hands it straight to Daraja B2C with no second source of truth:
--
--   .from('users').select('phone_number').eq('id', post.selected_provider_id)
--   → normalizePhone(...) → daraja.b2cPayout({ phone: providerPhone, ... })
--
-- So today, anyone who extracts the publishable key from the APK can PATCH any
-- provider's `phone_number` and have that provider's escrow release paid to a
-- number they control. `name`, `bio`, `avatar_url` and `profession` are
-- rewritable by the same route.
--
-- AFTER THIS MIGRATION
-- --------------------
--   * UPDATE: the row's owner only — `id = auth.jwt() ->> 'user_id'`, the same
--     Firebase UID every other ownership check in the system uses.
--   * anon loses UPDATE, DELETE and TRUNCATE. (DELETE was already refused for
--     want of a policy; TRUNCATE is NOT subject to RLS at all, so the grant was
--     the only thing standing between a public key and the users table.)
--   * SELECT and INSERT are deliberately untouched: the feed is browsable
--     logged-out, and sign-up still inserts anonymously before the token
--     exchange completes. Locking INSERT is a separate, later phase — the same
--     staging migration 076 used for posts.
--   * The backend keeps full access via service_role, which bypasses RLS.
--
-- CLIENT PREREQUISITE — ALREADY DONE
-- ----------------------------------
-- An owner-scoped policy needs the exchanged Supabase JWT; without it the
-- request is `anon` and matches zero rows. Thirteen client call sites wrote to
-- `users` and NONE established the session first (chat, applications and
-- reports all did — the identity table did not). They now route through two
-- guarded choke points, `UserProfileService._updateUser` and
-- `AuthService._upsertUserRow`, which await
-- `SupabaseAuthBridge.ensureSessionForWriteAsync()` and refuse rather than
-- attempt an unprovable write.
--
-- VERIFIED BEFORE APPLYING, by executing this exact policy inside a transaction
-- as each real role against real rows, then rolling back:
--   1. anon UPDATE on another user            → refused (insufficient_privilege)
--   2. authenticated owner editing own row    → 1 row
--   3. authenticated owner editing someone else → 0 rows
--   4. owner reassigning their own id         → refused
--
-- Rollback:
--   REVOKE UPDATE ON public.users FROM authenticated;
--   DROP POLICY IF EXISTS users_update_own ON public.users;
--   GRANT UPDATE ON public.users TO anon, authenticated;
--   CREATE POLICY "Users update by anon and authenticated" ON public.users
--     FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);
-- (Restoring it re-opens the payout redirect above.)
-- =============================================================================

REVOKE UPDATE, DELETE, TRUNCATE ON public.users FROM anon;
GRANT UPDATE ON public.users TO authenticated;

DROP POLICY IF EXISTS "Users update by anon and authenticated" ON public.users;
DROP POLICY IF EXISTS users_update ON public.users;
DROP POLICY IF EXISTS users_update_own ON public.users;

CREATE POLICY users_update_own ON public.users
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING      (id = (auth.jwt() ->> 'user_id'))
  WITH CHECK (id = (auth.jwt() ->> 'user_id'));

COMMENT ON POLICY users_update_own ON public.users IS
  'A profile is editable only by the person it belongs to. Ownership is the '
  'Firebase UID in the exchanged JWT, the same value posts.author_user_id and '
  'every other ownership check compare against.';
