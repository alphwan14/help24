-- =============================================================================
-- Migration 095 — fn_feed_candidates: signal-aware candidate retrieval
-- =============================================================================
-- THE CENTRAL FIX FROM THE FEED AUDIT.
--
-- The app's feed query is `ORDER BY created_at DESC LIMIT 50`. Ranking layered
-- on top of that can only reorder the newest fifty rows, so the nearest, most
-- relevant, most urgent post in the city is invisible the moment fifty newer
-- posts of any kind exist. No scoring function can repair a candidate set that
-- never contained the right answer.
--
-- This function replaces "newest N" with FOUR POOLS, each of which can put a
-- candidate in front of the ranker for a different reason:
--
--   nearby    — inside the viewer's bounding box            (proximity matters)
--   affinity  — in a category the viewer works in or opens  (relevance matters)
--   urgent    — live emergency                              (urgency matters)
--   fresh     — newest, unconditionally                     (discovery matters)
--
-- Every pool applies the SAME base predicate, including the caller's explicit
-- filters. Explicit filters are HARD: a user who filters to Plumbing never sees
-- anything else, no matter how the ranker would score it. Pools decide what is
-- *considered*; they never widen what the user asked for.
--
-- Returned rows are NARROW — scalars only, no images, no applications. Scoring
-- runs on ~400 of these; only the ~20 that survive are hydrated into full feed
-- rows by the backend. That is what makes the per-request cost constant as the
-- corpus grows.
--
-- SECURITY DEFINER + service_role-only EXECUTE: the backend calls this with the
-- service key. It reads users / provider_reputation / post_engagement, which
-- clients cannot read directly, and returns only fields already public on a
-- feed card plus ranking scalars.
--
-- SAFE + ADDITIVE — creates one function, changes no data.
-- Rollback: DROP FUNCTION public.fn_feed_candidates(...);  (full signature below)
-- =============================================================================

DROP FUNCTION IF EXISTS public.fn_feed_candidates(
  TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
  TEXT[], TEXT[], TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT, TEXT,
  TEXT[], INT, INT);

CREATE FUNCTION public.fn_feed_candidates(
  p_viewer_id           TEXT             DEFAULT NULL,
  p_lat                 DOUBLE PRECISION DEFAULT NULL,
  p_lng                 DOUBLE PRECISION DEFAULT NULL,
  p_radius_km           DOUBLE PRECISION DEFAULT 60,
  p_types               TEXT[]           DEFAULT NULL,  -- NULL = all types
  p_categories          TEXT[]           DEFAULT NULL,  -- explicit filter (hard)
  p_query               TEXT             DEFAULT NULL,
  p_min_price           NUMERIC          DEFAULT NULL,
  p_max_price           NUMERIC          DEFAULT NULL,
  p_urgency             TEXT             DEFAULT NULL,
  p_difficulty          TEXT             DEFAULT NULL,
  p_city                TEXT             DEFAULT NULL,
  p_area                TEXT             DEFAULT NULL,
  p_affinity_categories TEXT[]           DEFAULT NULL,  -- retrieval hint (soft)
  p_pool_limit          INT              DEFAULT 150,
  p_max_candidates      INT              DEFAULT 400
)
RETURNS TABLE (
  post_id              TEXT,
  author_user_id       TEXT,
  type                 TEXT,
  category             TEXT,
  status               TEXT,
  urgency              TEXT,
  difficulty           TEXT,
  price                DOUBLE PRECISION,
  location             TEXT,
  title                TEXT,
  description          TEXT,
  created_at           TIMESTAMPTZ,
  is_urgent            BOOLEAN,
  urgent_expires_at    TIMESTAMPTZ,
  latitude             DOUBLE PRECISION,
  longitude            DOUBLE PRECISION,
  distance_km          DOUBLE PRECISION,
  -- author
  author_profession    TEXT,
  author_is_verified   BOOLEAN,
  author_account_type  TEXT,
  author_available_until TIMESTAMPTZ,
  author_last_seen     TIMESTAMPTZ,
  -- reputation (NULL when the provider has no row yet — the engine treats
  -- that as "no history", which scores neutral, never zero)
  bayesian_rating      DOUBLE PRECISION,
  completion_rate      DOUBLE PRECISION,
  dispute_rate         DOUBLE PRECISION,
  total_reviews        INTEGER,
  completed_jobs       INTEGER,
  tier                 TEXT,
  -- engagement
  application_count    INTEGER,
  save_count           INTEGER,
  message_count        INTEGER,
  view_count           INTEGER,
  -- viewer relationship
  viewer_has_applied   BOOLEAN,
  is_own_post          BOOLEAN,
  -- which pool(s) surfaced this candidate (explainability)
  pools                TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_pool_limit INT := GREATEST(COALESCE(p_pool_limit, 150), 1);
  v_max        INT := GREATEST(COALESCE(p_max_candidates, 400), 1);
  v_radius     DOUBLE PRECISION := GREATEST(COALESCE(p_radius_km, 60), 0.1);
  v_has_coords BOOLEAN := p_lat IS NOT NULL AND p_lng IS NOT NULL;
  -- Bounding box. 111.045 km per degree of latitude; longitude degrees shrink
  -- by cos(latitude). Clamped so a viewer near a pole cannot produce a divide
  -- by ~0 and select the entire table.
  v_dlat DOUBLE PRECISION := v_radius / 111.045;
  v_dlng DOUBLE PRECISION := v_radius / GREATEST(111.045 * COS(RADIANS(COALESCE(p_lat, 0))), 1.0);
  v_like TEXT := CASE WHEN p_query IS NULL OR BTRIM(p_query) = ''
                      THEN NULL ELSE '%' || BTRIM(p_query) || '%' END;
BEGIN
  RETURN QUERY
  -- NOT MATERIALIZED is load-bearing, not a style choice. As a materialised CTE
  -- `base` would be computed ONCE IN FULL — every open post in the corpus —
  -- before any pool's LIMIT could apply, which is exactly the full scan this
  -- design exists to avoid. Inlined, the planner pushes each pool's ORDER BY +
  -- LIMIT down into the partial indexes from migration 094.
  WITH base AS NOT MATERIALIZED (
    -- Everything the caller EXPLICITLY asked for, applied once. Pools select
    -- from here, so no pool can ever leak a post past a user's filter.
    SELECT p.id, p.created_at, p.category, p.is_urgent, p.urgent_expires_at,
           p.latitude, p.longitude
    FROM public.posts p
    WHERE p.archived_at IS NULL
      AND p.status = 'open'
      AND (p_types      IS NULL OR p.type     = ANY(p_types))
      AND (p_categories IS NULL OR p.category = ANY(p_categories))
      AND (p_urgency    IS NULL OR p.urgency  = p_urgency)
      AND (p_difficulty IS NULL OR p.difficulty = p_difficulty)
      AND (p_min_price  IS NULL OR p.price >= p_min_price)
      AND (p_max_price  IS NULL OR p.price <= p_max_price)
      AND (p_city IS NULL OR p_city = '' OR p.location ILIKE '%' || p_city || '%')
      AND (p_area IS NULL OR p_area = '' OR p.location ILIKE '%' || p_area || '%')
      AND (v_like IS NULL
           OR p.title ILIKE v_like
           OR p.description ILIKE v_like
           OR p.category ILIKE v_like)
  ),
  -- ── Pool 1: nearby ─────────────────────────────────────────────────────────
  pool_nearby AS (
    SELECT b.id, b.created_at, 'nearby'::TEXT AS pool
    FROM base b
    WHERE v_has_coords
      AND b.latitude  IS NOT NULL
      AND b.longitude IS NOT NULL
      AND b.latitude  BETWEEN p_lat - v_dlat AND p_lat + v_dlat
      AND b.longitude BETWEEN p_lng - v_dlng AND p_lng + v_dlng
    ORDER BY b.created_at DESC
    LIMIT v_pool_limit
  ),
  -- ── Pool 2: affinity (profession + behaviour categories) ───────────────────
  pool_affinity AS (
    SELECT b.id, b.created_at, 'affinity'::TEXT AS pool
    FROM base b
    WHERE p_affinity_categories IS NOT NULL
      AND array_length(p_affinity_categories, 1) > 0
      AND b.category = ANY(p_affinity_categories)
    ORDER BY b.created_at DESC
    LIMIT v_pool_limit
  ),
  -- ── Pool 3: live emergencies ───────────────────────────────────────────────
  -- `urgent_expires_at` is a naked TIMESTAMP (migration 018) written by the app
  -- from a LOCAL DateTime. Comparing it against `NOW() AT TIME ZONE 'UTC'`
  -- reproduces exactly what PostService.fetchUrgentPosts already does, so this
  -- pool agrees with the existing Urgent pill rather than disagreeing with it.
  pool_urgent AS (
    SELECT b.id, b.created_at, 'urgent'::TEXT AS pool
    FROM base b
    WHERE b.is_urgent = TRUE
      AND b.urgent_expires_at IS NOT NULL
      AND b.urgent_expires_at > (NOW() AT TIME ZONE 'UTC')
    ORDER BY b.urgent_expires_at DESC
    LIMIT v_pool_limit
  ),
  -- ── Pool 4: fresh (discovery floor — new posts always get a chance) ────────
  pool_fresh AS (
    SELECT b.id, b.created_at, 'fresh'::TEXT AS pool
    FROM base b
    ORDER BY b.created_at DESC
    LIMIT v_pool_limit
  ),
  unioned AS (
    SELECT * FROM pool_nearby
    UNION ALL SELECT * FROM pool_affinity
    UNION ALL SELECT * FROM pool_urgent
    UNION ALL SELECT * FROM pool_fresh
  ),
  -- Dedupe, keeping every pool that surfaced the post (explainability: a
  -- candidate three pools agreed on is visibly a stronger candidate).
  deduped AS (
    SELECT
      x.id,
      MIN(x.created_at)                              AS created_at,
      COUNT(DISTINCT x.pool)                         AS pool_count,
      STRING_AGG(DISTINCT x.pool, ',' ORDER BY x.pool) AS pools
    FROM unioned x
    GROUP BY x.id
  ),
  -- Cap the working set. Ordering by pool breadth then recency means that when
  -- the cap bites it drops weakly-connected candidates first, never the ones
  -- multiple pools agreed on. No join back to `base` here: the ids already
  -- passed every filter, so the final SELECT reads `posts` by primary key.
  capped AS (
    SELECT d.id, d.pools
    FROM deduped d
    ORDER BY d.pool_count DESC, d.created_at DESC
    LIMIT v_max
  )
  SELECT
    b.id::TEXT,
    COALESCE(b.author_user_id, ''),
    b.type,
    b.category,
    b.status,
    b.urgency,
    b.difficulty,
    COALESCE(b.price, 0)::DOUBLE PRECISION,
    b.location,
    b.title,
    b.description,
    b.created_at,
    COALESCE(b.is_urgent, FALSE),
    -- Reinterpreted as UTC rather than cast through the session timezone, so
    -- the value the ranker sees never depends on the server's TimeZone setting.
    (b.urgent_expires_at AT TIME ZONE 'UTC'),
    b.latitude,
    b.longitude,
    CASE
      WHEN v_has_coords AND b.latitude IS NOT NULL AND b.longitude IS NOT NULL THEN
        -- Haversine. asin(least(1, …)) guards the float rounding that can push
        -- the argument marginally above 1 for near-identical points.
        2 * 6371.0 * ASIN(LEAST(1.0, SQRT(
            POWER(SIN(RADIANS(b.latitude - p_lat) / 2), 2)
          + COS(RADIANS(p_lat)) * COS(RADIANS(b.latitude))
          * POWER(SIN(RADIANS(b.longitude - p_lng) / 2), 2)
        )))
      ELSE NULL
    END,
    u.profession,
    COALESCE(u.is_verified, FALSE),
    COALESCE(u.account_type, 'individual'),
    u.available_until,
    u.last_seen,
    pr.bayesian_rating,
    pr.completion_rate,
    pr.dispute_rate,
    pr.total_reviews,
    pr.completed_jobs,
    pr.tier,
    COALESCE(pe.application_count, 0),
    COALESCE(pe.save_count, 0),
    COALESCE(pe.message_count, 0),
    COALESCE(pe.view_count, 0),
    (app.post_id IS NOT NULL),
    (p_viewer_id IS NOT NULL AND p_viewer_id <> '' AND b.author_user_id = p_viewer_id),
    c.pools
  FROM capped c
  JOIN public.posts b                    ON b.id = c.id
  LEFT JOIN public.users u               ON u.id = b.author_user_id
  LEFT JOIN public.provider_reputation pr ON pr.provider_id = b.author_user_id
  LEFT JOIN public.post_engagement pe     ON pe.post_id = b.id::TEXT
  LEFT JOIN LATERAL (
    SELECT a.post_id
    FROM public.applications a
    WHERE a.post_id = b.id
      AND p_viewer_id IS NOT NULL AND p_viewer_id <> ''
      AND a.applicant_user_id = p_viewer_id
    LIMIT 1
  ) app ON TRUE;
END;
$func$;

REVOKE ALL ON FUNCTION public.fn_feed_candidates(
  TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
  TEXT[], TEXT[], TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT, TEXT,
  TEXT[], INT, INT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.fn_feed_candidates(
  TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
  TEXT[], TEXT[], TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT, TEXT,
  TEXT[], INT, INT) TO service_role;

COMMENT ON FUNCTION public.fn_feed_candidates(
  TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
  TEXT[], TEXT[], TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT, TEXT,
  TEXT[], INT, INT) IS
  'Discover candidate generation: 4 signal-aware pools (nearby / affinity / '
  'urgent / fresh) over one shared, filter-respecting base predicate. Returns '
  'narrow rows with every ranking scalar attached. Bounded by p_max_candidates, '
  'so cost is constant in corpus size. Scored by backend/src/feed/ranking.';
