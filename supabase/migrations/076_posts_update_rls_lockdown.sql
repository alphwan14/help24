-- =============================================================================
-- Migration 076 — posts UPDATE/DELETE lockdown (author-only)
-- =============================================================================
-- Closes the exposure confirmed in the profile audit: posts UPDATE was
-- USING(true) WITH CHECK(true) and GRANTed to anon — ANY holder of the public
-- key could edit any post, including setting another user as
-- selected_provider_id on a cancelled post to poison that provider's
-- completion/dispute rates (which 075's trigger would then faithfully bake in).
--
-- After this migration:
--   * UPDATE / DELETE: post author only (authenticated JWT user_id claim).
--   * Backend keeps full access via service_role (bypasses RLS) — provider
--     selection, approval, archive, and admin decisions are all backend-run
--     and unaffected.
--   * SELECT and INSERT are deliberately untouched: the feed is browsable
--     logged-out, and posting still runs through the app's own auth gate.
--     Locking INSERT is a separate, later phase.
--
-- ⚠️ HARD PREREQUISITE — same gate as migration 061: S1 verified, i.e. the
-- exchange-firebase-token bridge returns [AUTH][BRIDGE] ok=true on device.
-- Client-side post edits/deletes run as `authenticated` only when the bridge
-- works; applying this while clients are anon breaks the owner's own
-- edit/delete actions (everything backend-mediated keeps working).
--
-- Rollback:
--   GRANT UPDATE, DELETE ON public.posts TO anon, authenticated;
--   DROP POLICY IF EXISTS posts_update_owner ON public.posts;
--   DROP POLICY IF EXISTS posts_delete_owner ON public.posts;
--   CREATE POLICY posts_update ON public.posts FOR UPDATE USING (true) WITH CHECK (true);
--   CREATE POLICY posts_delete ON public.posts FOR DELETE USING (true);
-- =============================================================================

REVOKE UPDATE, DELETE ON public.posts FROM anon;
GRANT UPDATE, DELETE ON public.posts TO authenticated;

-- Drop every permissive UPDATE/DELETE policy this table has accumulated
-- (bootstrap schema + migration 022 used different names).
DROP POLICY IF EXISTS posts_update ON public.posts;
DROP POLICY IF EXISTS posts_update_author ON public.posts;
DROP POLICY IF EXISTS "Posts update" ON public.posts;
DROP POLICY IF EXISTS posts_delete ON public.posts;
DROP POLICY IF EXISTS "Posts delete" ON public.posts;

CREATE POLICY posts_update_owner ON public.posts
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING      (author_user_id = (auth.jwt() ->> 'user_id'))
  WITH CHECK (author_user_id = (auth.jwt() ->> 'user_id'));

CREATE POLICY posts_delete_owner ON public.posts
  AS PERMISSIVE FOR DELETE TO authenticated
  USING (author_user_id = (auth.jwt() ->> 'user_id'));
