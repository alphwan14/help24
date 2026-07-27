-- =============================================================================
-- Migration 091 — user_interactions: the behavioural substrate
-- =============================================================================
-- Today Help24 instruments SPONSORED cards (promotion_events, 078) and nothing
-- else. The product therefore knows exactly what advertisers paid for and
-- nothing about what users actually want. Signals 9 (user behaviour) and 10
-- (search history) in the recommendation spec have no data to stand on.
--
-- This table is that data. Append-only, one row per event, owner-scoped.
--
-- WHY A SEPARATE TABLE FROM promotion_events
-- ------------------------------------------
-- promotion_events is billing evidence: it is written for campaign accounting,
-- retained on a billing schedule, and read by advertiser analytics. This table
-- is personalisation input: pruned on a privacy schedule (180 days), read only
-- by the ranking engine, and never shown to anyone but its owner. Conflating
-- the two would put ad billing and user privacy on the same retention clock.
--
-- WHAT IS DELIBERATELY NOT STORED
-- -------------------------------
--   * no free-text beyond the user's own search queries;
--   * no location trail (the feed reads live coordinates per request instead);
--   * no cross-user identifiers — `author_id` is the SUBJECT of the event, and
--     is only ever read back into the SAME user's own affinity.
--
-- SAFE + ADDITIVE. Rollback:
--   DROP FUNCTION public.fn_prune_user_interactions();
--   DROP FUNCTION public.fn_user_affinity(TEXT, DOUBLE PRECISION, INT, INT, JSONB, INT, DOUBLE PRECISION);
--   DROP TABLE public.user_interactions;
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.user_interactions (
  id          BIGSERIAL   PRIMARY KEY,
  user_id     TEXT        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  kind        TEXT        NOT NULL CHECK (kind IN (
                            'impression', 'open', 'save', 'unsave', 'apply',
                            'message', 'hire', 'search', 'category_open',
                            'profile_open')),
  -- All subject columns are nullable: a 'search' has no post, a 'category_open'
  -- has no author. No FKs — a pruned/archived post must never block an insert
  -- and must never cascade-delete a user's affinity history.
  post_id     TEXT,
  author_id   TEXT,
  category    TEXT,        -- categories.name (matches posts.category)
  profession  TEXT,        -- professions.id slug
  query       TEXT,        -- kind='search' only
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- The ONLY access pattern: "this user's recent events, newest first".
-- Every affinity read is bounded by user_id + a lookback window, so this single
-- index serves the entire behavioural half of the engine.
CREATE INDEX IF NOT EXISTS idx_user_interactions_user_created
  ON public.user_interactions (user_id, created_at DESC);

-- Pruning scans by age alone.
CREATE INDEX IF NOT EXISTS idx_user_interactions_created
  ON public.user_interactions (created_at);

-- Per-post aggregation for the engagement counters (092). Partial, because a
-- 'search' row has no post and would only bloat the index.
CREATE INDEX IF NOT EXISTS idx_user_interactions_post
  ON public.user_interactions (post_id)
  WHERE post_id IS NOT NULL;

ALTER TABLE public.user_interactions ENABLE ROW LEVEL SECURITY;

-- Owner scoping via auth.jwt() ->> 'user_id' — never auth.uid(); the Firebase
-- sub is not a UUID. Same convention as 061/080/081/082.
-- INSERT + SELECT only: a behavioural log that can be edited is not a log.
DROP POLICY IF EXISTS user_interactions_owner_insert ON public.user_interactions;
CREATE POLICY user_interactions_owner_insert ON public.user_interactions
  FOR INSERT TO authenticated
  WITH CHECK (user_id = (auth.jwt() ->> 'user_id'));

DROP POLICY IF EXISTS user_interactions_owner_select ON public.user_interactions;
CREATE POLICY user_interactions_owner_select ON public.user_interactions
  FOR SELECT TO authenticated
  USING (user_id = (auth.jwt() ->> 'user_id'));

DROP POLICY IF EXISTS user_interactions_service_role ON public.user_interactions;
CREATE POLICY user_interactions_service_role ON public.user_interactions
  TO service_role
  USING (true) WITH CHECK (true);

GRANT SELECT, INSERT ON public.user_interactions TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.user_interactions_id_seq TO authenticated;
GRANT ALL ON public.user_interactions TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.user_interactions_id_seq TO service_role;

-- =============================================================================
-- fn_user_affinity — one round trip for the whole viewer profile
-- =============================================================================
-- Returns time-decayed affinity across three dimensions plus the viewer's
-- recent search queries, in ONE result set:
--
--   dimension | key                      | weight
--   ----------+--------------------------+--------
--   category  | 'Electrical'             | 1.00     (normalised per dimension)
--   profession| 'electrician'            | 0.62
--   author    | 'firebase-uid-of-author' | 0.41
--   search    | 'laptop repair'          | 0.88     (decayed by query age)
--
-- weight = Σ event_weight · exp(−age_days / halflife), then min-max normalised
-- to 0..1 WITHIN each dimension, so a heavy user and a light user both produce
-- comparable inputs to the ranking engine.
--
-- Cost is bounded by (user_id, created_at DESC) + p_lookback_days, never by
-- table size. p_event_weights is passed in from feed_settings so event
-- weighting stays tunable without a migration.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_user_affinity(
  p_user_id        TEXT,
  p_halflife_days  DOUBLE PRECISION DEFAULT 14,
  p_lookback_days  INT              DEFAULT 90,
  p_limit          INT              DEFAULT 20,
  p_event_weights  JSONB            DEFAULT NULL,
  p_search_lookback_days   INT              DEFAULT 7,
  p_search_halflife_hours  DOUBLE PRECISION DEFAULT 48
)
RETURNS TABLE (dimension TEXT, key TEXT, weight DOUBLE PRECISION)
LANGUAGE plpgsql
STABLE
AS $func$
DECLARE
  v_weights JSONB := COALESCE(p_event_weights, '{
    "hire": 8, "apply": 5, "message": 4, "save": 3, "search": 2,
    "category_open": 1.5, "open": 1, "profile_open": 1,
    "impression": 0.05, "unsave": -3
  }'::jsonb);
BEGIN
  IF p_user_id IS NULL OR p_user_id = '' THEN RETURN; END IF;

  RETURN QUERY
  WITH raw AS (
    SELECT
      ui.kind,
      ui.category,
      ui.profession,
      ui.author_id,
      ui.query,
      ui.created_at,
      -- Unknown kinds score 0 rather than NULL, so a future event kind added by
      -- a newer client can never poison an existing user's affinity.
      COALESCE((v_weights ->> ui.kind)::DOUBLE PRECISION, 0) AS event_weight,
      EXTRACT(EPOCH FROM (NOW() - ui.created_at)) / 86400.0   AS age_days
    FROM public.user_interactions ui
    WHERE ui.user_id = p_user_id
      AND ui.created_at > NOW() - MAKE_INTERVAL(days => p_lookback_days)
  ),
  decayed AS (
    SELECT *, event_weight * EXP(-age_days / GREATEST(p_halflife_days, 0.5)) AS w
    FROM raw
  ),
  -- ── category ──────────────────────────────────────────────────────────────
  cat AS (
    SELECT 'category'::TEXT AS dim, category AS k, SUM(w) AS total
    FROM decayed WHERE category IS NOT NULL AND category <> ''
    GROUP BY category
  ),
  -- ── profession ────────────────────────────────────────────────────────────
  prof AS (
    SELECT 'profession'::TEXT AS dim, profession AS k, SUM(w) AS total
    FROM decayed WHERE profession IS NOT NULL AND profession <> ''
    GROUP BY profession
  ),
  -- ── author ────────────────────────────────────────────────────────────────
  auth AS (
    SELECT 'author'::TEXT AS dim, author_id AS k, SUM(w) AS total
    FROM decayed WHERE author_id IS NOT NULL AND author_id <> ''
    GROUP BY author_id
  ),
  -- ── searches (own decay clock: a query goes stale in days, not weeks) ─────
  searches AS (
    SELECT 'search'::TEXT AS dim,
           LOWER(BTRIM(query)) AS k,
           MAX(EXP(
             -(EXTRACT(EPOCH FROM (NOW() - created_at)) / 3600.0)
             / GREATEST(p_search_halflife_hours, 1)
           )) AS total
    FROM raw
    WHERE kind = 'search'
      AND query IS NOT NULL AND BTRIM(query) <> ''
      AND created_at > NOW() - MAKE_INTERVAL(days => p_search_lookback_days)
    GROUP BY LOWER(BTRIM(query))
  ),
  unioned AS (
    SELECT * FROM cat
    UNION ALL SELECT * FROM prof
    UNION ALL SELECT * FROM auth
    UNION ALL SELECT * FROM searches
  ),
  -- Drop non-positive affinity (an 'unsave' can drive a key negative — that is
  -- correct arithmetic but "slightly negative" is not a useful ranking input).
  positive AS (
    SELECT * FROM unioned WHERE total > 0
  ),
  ranked AS (
    SELECT
      dim, k, total,
      MAX(total) OVER (PARTITION BY dim) AS dim_max,
      ROW_NUMBER() OVER (PARTITION BY dim ORDER BY total DESC, k ASC) AS rn
    FROM positive
  )
  SELECT r.dim, r.k, (r.total / NULLIF(r.dim_max, 0))::DOUBLE PRECISION
  FROM ranked r
  WHERE r.rn <= GREATEST(p_limit, 1)
  ORDER BY r.dim, 3 DESC;
END;
$func$;

REVOKE ALL ON FUNCTION public.fn_user_affinity(TEXT, DOUBLE PRECISION, INT, INT, JSONB, INT, DOUBLE PRECISION) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_user_affinity(TEXT, DOUBLE PRECISION, INT, INT, JSONB, INT, DOUBLE PRECISION) TO service_role;

-- =============================================================================
-- Retention — personalisation data is not kept forever
-- =============================================================================
-- 180 days is well past the 90-day affinity lookback, so pruning can never
-- change a live recommendation. Call from an existing sweep or a cron job.
CREATE OR REPLACE FUNCTION public.fn_prune_user_interactions(p_keep_days INT DEFAULT 180)
RETURNS BIGINT
LANGUAGE plpgsql
AS $func$
DECLARE
  v_deleted BIGINT;
BEGIN
  DELETE FROM public.user_interactions
  WHERE created_at < NOW() - MAKE_INTERVAL(days => GREATEST(p_keep_days, 1));
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$func$;

REVOKE ALL ON FUNCTION public.fn_prune_user_interactions(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_prune_user_interactions(INT) TO service_role;

COMMENT ON TABLE public.user_interactions IS
  'Append-only behavioural log feeding Discover personalisation (signals 9 and '
  '10). Owner-scoped RLS, INSERT+SELECT only, pruned at 180 days by '
  'fn_prune_user_interactions. Read exclusively via fn_user_affinity.';
