-- =============================================================================
-- Migration 092 — post_engagement: denormalised counters for the engagement signal
-- =============================================================================
-- The engagement signal needs, per candidate post: how many people applied,
-- saved it, and messaged about it. Computing that at read time means an
-- aggregate over `applications` + `saved_items` + `user_interactions` for every
-- one of ~400 candidates on every feed request — precisely the N² the
-- recommendation spec forbids.
--
-- So the counters are maintained on write, in a table of their own.
--
-- WHY NOT COLUMNS ON `posts`
-- --------------------------
-- `posts` is the hottest table in the product: every feed read, every filter,
-- every RLS check touches it. Adding four counters updated by triggers would
-- put a row-level write on `posts` behind every impression and every save,
-- inflating its bloat and invalidating its indexes constantly. A narrow side
-- table keeps that churn off the read path.
--
-- CORRECTNESS
-- -----------
-- Counters are derived, and `fn_recompute_post_engagement(post_id)` recomputes
-- any row from canonical tables idempotently — same contract as
-- provider_reputation (055). If a counter ever drifts, it is repairable; it is
-- never the source of truth. Triggers use it directly rather than doing
-- "current + 1" arithmetic, so a replayed or out-of-order event cannot
-- accumulate error.
--
-- SAFE + ADDITIVE. Rollback:
--   DROP TRIGGER trg_engagement_applications ON public.applications;
--   DROP TRIGGER trg_engagement_saved_items  ON public.saved_items;
--   DROP TRIGGER trg_engagement_interactions ON public.user_interactions;
--   DROP FUNCTION public.fn_touch_post_engagement();
--   DROP FUNCTION public.fn_recompute_post_engagement(TEXT);
--   DROP TABLE public.post_engagement;
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.post_engagement (
  post_id            TEXT        PRIMARY KEY,
  application_count  INTEGER     NOT NULL DEFAULT 0,
  save_count         INTEGER     NOT NULL DEFAULT 0,
  message_count      INTEGER     NOT NULL DEFAULT 0,
  view_count         INTEGER     NOT NULL DEFAULT 0,
  last_engagement_at TIMESTAMPTZ,
  recomputed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.post_engagement ENABLE ROW LEVEL SECURITY;

-- Server-only: these counts are ranking input, and exposing them to clients
-- would let anyone measure exactly how much a fabricated view raises a post.
DROP POLICY IF EXISTS post_engagement_service_role ON public.post_engagement;
CREATE POLICY post_engagement_service_role ON public.post_engagement
  TO service_role
  USING (true) WITH CHECK (true);

GRANT ALL ON public.post_engagement TO service_role;

-- =============================================================================
-- Idempotent recompute — the single definition of every counter
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fn_recompute_post_engagement(p_post_id TEXT)
RETURNS void
LANGUAGE plpgsql
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

REVOKE ALL ON FUNCTION public.fn_recompute_post_engagement(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_recompute_post_engagement(TEXT) TO service_role;

-- =============================================================================
-- Triggers — recompute the affected post, never increment
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fn_touch_post_engagement()
RETURNS TRIGGER
LANGUAGE plpgsql
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
    PERFORM public.fn_recompute_post_engagement(v_post_id);
  END IF;
  RETURN NULL;  -- AFTER trigger; return value is ignored
END;
$func$;

DROP TRIGGER IF EXISTS trg_engagement_applications ON public.applications;
CREATE TRIGGER trg_engagement_applications
  AFTER INSERT OR DELETE ON public.applications
  FOR EACH ROW EXECUTE FUNCTION public.fn_touch_post_engagement('post_id');

DROP TRIGGER IF EXISTS trg_engagement_saved_items ON public.saved_items;
CREATE TRIGGER trg_engagement_saved_items
  AFTER INSERT OR DELETE ON public.saved_items
  FOR EACH ROW EXECUTE FUNCTION public.fn_touch_post_engagement('item_id');

-- Only the kinds that move a counter fire a recompute. Without this WHEN clause
-- every impression on every card would trigger a multi-table aggregate — the
-- exact cost this table exists to avoid.
--
-- Consequence, deliberately accepted: `view_count` (opens + impressions) is
-- refreshed only when an `open` or `message` lands, so impression-only posts
-- carry a stale view count until the next recompute. That is harmless — raw
-- views contribute ZERO to the engagement score by design (see the `engagement`
-- key in feed_settings); the counter exists for analytics and future signals.
DROP TRIGGER IF EXISTS trg_engagement_interactions ON public.user_interactions;
CREATE TRIGGER trg_engagement_interactions
  AFTER INSERT ON public.user_interactions
  FOR EACH ROW
  WHEN (NEW.post_id IS NOT NULL AND NEW.kind IN ('message', 'open'))
  EXECUTE FUNCTION public.fn_touch_post_engagement('post_id');

-- ── Backfill: every existing post gets a truthful row ────────────────────────
INSERT INTO public.post_engagement (post_id, application_count, save_count, recomputed_at)
SELECT
  p.id::text,
  COALESCE(a.cnt, 0),
  COALESCE(s.cnt, 0),
  NOW()
FROM public.posts p
LEFT JOIN (
  SELECT post_id, COUNT(*) AS cnt FROM public.applications GROUP BY post_id
) a ON a.post_id = p.id
LEFT JOIN (
  SELECT item_id, COUNT(*) AS cnt FROM public.saved_items
  WHERE item_type = 'post' GROUP BY item_id
) s ON s.item_id = p.id::text
ON CONFLICT (post_id) DO NOTHING;

COMMENT ON TABLE public.post_engagement IS
  'Derived engagement counters for Discover ranking signal 6. Maintained by '
  'triggers that call fn_recompute_post_engagement (idempotent, never '
  'incremental). Repairable from canonical tables at any time; never a source '
  'of truth. Server-only.';
