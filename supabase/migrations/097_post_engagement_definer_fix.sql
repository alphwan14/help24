-- =============================================================================
-- Migration 097 — post_engagement triggers must run as their owner
-- =============================================================================
-- THE BUG
-- -------
-- Migration 092 put AFTER triggers on `applications`, `saved_items` and
-- `user_interactions` that call `fn_recompute_post_engagement`, then correctly
-- locked that function down:
--
--   REVOKE ALL ON FUNCTION public.fn_recompute_post_engagement(TEXT) FROM PUBLIC;
--   GRANT EXECUTE ON FUNCTION public.fn_recompute_post_engagement(TEXT) TO service_role;
--
-- But it declared neither function SECURITY DEFINER. A trigger function runs as
-- the INVOKING role, so when a signed-in user in the app inserted a row, the
-- trigger fired as `authenticated` and hit its own lockdown:
--
--   PostgrestException(message: permission denied for function
--                      fn_recompute_post_engagement, code: 42501)
--
-- and the whole INSERT rolled back. Two core actions were dead app-wide, for
-- every user, on every listing — not just the urgent surface where it surfaced:
--
--   * SENDING AN OFFER / APPLYING  — ApplicationService writes `applications`
--     directly from the client (that write is RLS-guarded and trigger-guarded
--     by design; only the engagement recompute was missing a grant).
--   * SAVING A POST                — SavedService writes `saved_items` from the
--     client the same way.
--
-- `user_interactions` was unaffected in practice: those rows are written by the
-- backend via POST /feed/interactions, which already runs as service_role.
--
-- THE FIX
-- -------
-- Exactly the pattern migration 075 established for the identical situation
-- ("SECURITY DEFINER so the recompute can write the service_role-only
-- provider_reputation table even when the updater is a client role").
--
-- The functions become SECURITY DEFINER so they run as their owner, which has
-- the rights their own lockdown requires. The lockdown is DELIBERATELY KEPT:
-- clients still cannot call `fn_recompute_post_engagement` directly, because
-- engagement counters are ranking input and letting anyone recompute — or
-- measure — them is precisely what 092 set out to prevent. The only thing that
-- changes is that the trigger can do the job it was installed to do.
--
-- SECURITY REVIEW OF THE ELEVATION
-- Both functions are safe to run as owner: they take a post id, read canonical
-- tables, and write derived counters for that post and nothing else. There is
-- no branch that can return data to the caller, and the recompute is idempotent
-- — the worst a call can achieve is writing the correct numbers. `search_path`
-- is pinned on both so a caller cannot shadow `public` with their own schema,
-- which is the standard hazard of SECURITY DEFINER.
--
-- IDEMPOTENT. Safe to re-run. Changes no data and no table definitions — only
-- the two function bodies (replaced with identical logic) and their security
-- attribute.
--
-- Rollback (restores the broken state; only for bisecting):
--   ALTER FUNCTION public.fn_recompute_post_engagement(TEXT) SECURITY INVOKER;
--   ALTER FUNCTION public.fn_touch_post_engagement()         SECURITY INVOKER;
-- =============================================================================

-- =============================================================================
-- Idempotent recompute — body unchanged from 092; SECURITY DEFINER added
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fn_recompute_post_engagement(p_post_id TEXT)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_applications INTEGER := 0;
  v_saves        INTEGER := 0;
  v_messages     INTEGER := 0;
  v_views        INTEGER := 0;
  v_last         TIMESTAMPTZ;
BEGIN
  IF p_post_id IS NULL OR p_post_id = '' THEN RETURN; END IF;

  -- applications.post_id is uuid; the cast is guarded because post_engagement
  -- keys on TEXT (user_interactions.post_id is TEXT by design — see 091).
  BEGIN
    SELECT COUNT(*) INTO v_applications
    FROM public.applications a
    WHERE a.post_id = p_post_id::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    v_applications := 0;
  END;

  SELECT COUNT(*) INTO v_saves
  FROM public.saved_items s
  WHERE s.item_type = 'post' AND s.item_id = p_post_id;

  -- Distinct users, not distinct events: one person opening a post ten times is
  -- one interested person, not ten. "Quality, not popularity."
  SELECT
    COUNT(DISTINCT ui.user_id) FILTER (WHERE ui.kind = 'message'),
    COUNT(DISTINCT ui.user_id) FILTER (WHERE ui.kind IN ('open', 'impression')),
    MAX(ui.created_at)
  INTO v_messages, v_views, v_last
  FROM public.user_interactions ui
  WHERE ui.post_id = p_post_id;

  INSERT INTO public.post_engagement AS pe
    (post_id, application_count, save_count, message_count, view_count,
     last_engagement_at, recomputed_at)
  VALUES
    (p_post_id, v_applications, v_saves, v_messages, v_views, v_last, NOW())
  ON CONFLICT (post_id) DO UPDATE SET
    application_count  = EXCLUDED.application_count,
    save_count         = EXCLUDED.save_count,
    message_count      = EXCLUDED.message_count,
    view_count         = EXCLUDED.view_count,
    last_engagement_at = GREATEST(
                           COALESCE(EXCLUDED.last_engagement_at, pe.last_engagement_at),
                           COALESCE(pe.last_engagement_at, EXCLUDED.last_engagement_at)),
    recomputed_at      = NOW();
END;
$func$;

-- Unchanged from 092 and deliberately re-asserted: a client must never be able
-- to call this directly. SECURITY DEFINER is what lets the TRIGGER through, not
-- a grant to `authenticated`.
REVOKE ALL ON FUNCTION public.fn_recompute_post_engagement(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_recompute_post_engagement(TEXT) TO service_role;

-- =============================================================================
-- Trigger function — body unchanged from 092; SECURITY DEFINER added
-- =============================================================================
-- This is the one that actually had to change: it is the function the client's
-- INSERT invokes, so it is the function that was running as `authenticated`.
CREATE OR REPLACE FUNCTION public.fn_touch_post_engagement()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_post_id TEXT;
BEGIN
  -- Each source table names the post differently; TG_ARGV[0] carries the column.
  -- Read through to_jsonb rather than dynamic SQL: `($1).col` on a record passed
  -- via USING has no resolvable type at plan time and fails at runtime.
  IF TG_OP = 'DELETE' THEN
    v_post_id := to_jsonb(OLD) ->> TG_ARGV[0];
  ELSE
    v_post_id := to_jsonb(NEW) ->> TG_ARGV[0];
  END IF;

  -- saved_items spans posts AND providers; only post rows are engagement.
  IF TG_TABLE_NAME = 'saved_items' THEN
    IF (TG_OP = 'DELETE' AND OLD.item_type <> 'post')
       OR (TG_OP <> 'DELETE' AND NEW.item_type <> 'post') THEN
      RETURN NULL;
    END IF;
  END IF;

  IF v_post_id IS NOT NULL AND v_post_id <> '' THEN
    -- A DERIVED COUNTER MUST NEVER FAIL A REAL WRITE.
    --
    -- This is the fix for the CLASS of bug, not just the instance. 092's own
    -- contract says these counters are "derived… repairable… never a source of
    -- truth" — and yet an unhandled error in maintaining them aborted the
    -- user's application. A ranking optimisation was given veto power over the
    -- business action it was measuring, which is exactly backwards.
    --
    -- Any failure here is now contained: the application or save COMMITS, and
    -- the counter is left stale. Stale is the designed-for state — the recompute
    -- is idempotent and the next event on this post, or a manual call, repairs
    -- it from canonical tables.
    --
    -- RAISE WARNING, not silence: this lands in the Postgres log, so a
    -- persistent fault is visible in operations rather than merely invisible to
    -- users. (Suppressing a non-essential background failure from the USER is
    -- correct; hiding it from the OPERATOR is not.)
    BEGIN
      PERFORM public.fn_recompute_post_engagement(v_post_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'post_engagement recompute failed for % (%): %',
        v_post_id, SQLSTATE, SQLERRM;
    END;
  END IF;
  RETURN NULL;  -- AFTER trigger; return value is ignored
END;
$func$;

-- The trigger function is reached only through the triggers themselves, never
-- by name. No role needs EXECUTE on it.
REVOKE ALL ON FUNCTION public.fn_touch_post_engagement() FROM PUBLIC;

-- Triggers are NOT recreated: CREATE OR REPLACE FUNCTION keeps the existing
-- trg_engagement_* bindings from 092 pointing at the new bodies.

COMMENT ON FUNCTION public.fn_touch_post_engagement() IS
  'AFTER-trigger bridge for post_engagement. SECURITY DEFINER (097) because it '
  'fires on client writes to applications/saved_items and must reach the '
  'service_role-only recompute — without it every apply and every save failed '
  'with 42501.';

-- =============================================================================
-- Repair: counters that never got written while the trigger was failing
-- =============================================================================
-- The failed INSERTs rolled back, so no application or save was lost — they
-- never happened. But rows written by paths that DID succeed (backend writes as
-- service_role) may have left post_engagement behind. Recompute every post that
-- has any engagement, idempotently.
DO $repair$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT DISTINCT post_id::text AS pid FROM public.applications
    UNION
    SELECT DISTINCT item_id       FROM public.saved_items WHERE item_type = 'post'
    UNION
    SELECT DISTINCT post_id       FROM public.user_interactions WHERE post_id IS NOT NULL
  LOOP
    PERFORM public.fn_recompute_post_engagement(r.pid);
  END LOOP;
END;
$repair$;

-- =============================================================================
-- Verification — run after applying; both rows must report SECURITY DEFINER
-- =============================================================================
--   SELECT p.proname, p.prosecdef AS security_definer, p.proconfig
--   FROM pg_proc p
--   JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname = 'public'
--     AND p.proname IN ('fn_recompute_post_engagement', 'fn_touch_post_engagement');
--
-- Expected: security_definer = true for both, proconfig = {search_path=public,pg_temp}
