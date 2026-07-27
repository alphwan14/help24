-- =============================================================================
-- Migration 094 — indexes the recommendation engine actually needs
-- =============================================================================
-- Today `posts` is indexed for recency and for point lookups. The feed audit
-- found nothing supporting the predicates ranking depends on:
--
--   * the real feed predicate is (archived_at IS NULL AND status='open'),
--     never just created_at — so idx_posts_created_at scans dead rows;
--   * idx_posts_lat_lng is a plain btree on (latitude, longitude), which
--     cannot serve a bounding-box range on BOTH axes;
--   * `category` has no index at all, and it is the profession-matching join key;
--   * every search is `ilike '%…%'`, which no btree can serve — guaranteed
--     sequential scan on every keystroke.
--
-- All indexes here are PARTIAL on the live-post predicate. That is the whole
-- trick for scale: the index only ever contains rows the feed can actually
-- return, so it stays small as the archive grows without bound.
--
-- SAFE + ADDITIVE, and idempotent. This migration only creates indexes.
--
-- ⚠️ RUNTIME NOTE — apply during a quiet window, or split it.
-- CREATE INDEX takes a SHARE lock (writes to `posts` block for its duration).
-- On a large table run each statement separately with CONCURRENTLY instead:
--     CREATE INDEX CONCURRENTLY idx_… ;   -- cannot run inside a transaction
-- The Supabase SQL editor wraps statements in a transaction, so CONCURRENTLY
-- must be run one statement at a time from psql. At Help24's current volume
-- the plain form below takes well under a second.
--
-- Rollback: DROP INDEX for each name below.
-- =============================================================================

-- pg_trgm powers substring search. Without it, `ilike '%plumb%'` cannot use an
-- index under any circumstances.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ── 1. The actual feed predicate ─────────────────────────────────────────────
-- Serves the `fresh` retrieval pool and every unfiltered feed page.
CREATE INDEX IF NOT EXISTS idx_posts_feed_live
  ON public.posts (created_at DESC)
  WHERE archived_at IS NULL AND status = 'open';

-- ── 2. Type-scoped feed (Requests / Offers tabs, Jobs screen) ────────────────
CREATE INDEX IF NOT EXISTS idx_posts_feed_type
  ON public.posts (type, created_at DESC)
  WHERE archived_at IS NULL AND status = 'open';

-- ── 3. Category — the profession-matching join key and the `affinity` pool ───
CREATE INDEX IF NOT EXISTS idx_posts_feed_category
  ON public.posts (category, created_at DESC)
  WHERE archived_at IS NULL AND status = 'open';

-- ── 4. Proximity — the `nearby` pool's bounding box ──────────────────────────
-- latitude leads because it prunes hardest (a 60 km window is ±0.54° of
-- latitude regardless of where on Earth you are, whereas the longitude window
-- widens toward the poles).
CREATE INDEX IF NOT EXISTS idx_posts_feed_geo
  ON public.posts (latitude, longitude, created_at DESC)
  WHERE archived_at IS NULL AND status = 'open' AND latitude IS NOT NULL;

-- ── 5. Live emergencies — the `urgent` pool ──────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_posts_feed_urgent
  ON public.posts (urgent_expires_at DESC)
  WHERE archived_at IS NULL AND status = 'open' AND is_urgent = TRUE;

-- ── 6. Search ────────────────────────────────────────────────────────────────
-- GIN + gin_trgm_ops is what turns `ilike '%…%'` from a sequential scan into an
-- index scan. Two separate indexes rather than one over a concatenation, so the
-- planner can use whichever column the query actually touches.
CREATE INDEX IF NOT EXISTS idx_posts_title_trgm
  ON public.posts USING GIN (title gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_posts_description_trgm
  ON public.posts USING GIN (description gin_trgm_ops);

-- `location` is still matched with ilike by the explicit city/area filters.
CREATE INDEX IF NOT EXISTS idx_posts_location_trgm
  ON public.posts USING GIN (location gin_trgm_ops);

-- ── 7. Author capping / own-post detection ───────────────────────────────────
-- idx_posts_author_user_id (004) already covers this, but not scoped to live
-- posts; this partial version is what the feed's anti-spam pass reads.
CREATE INDEX IF NOT EXISTS idx_posts_feed_author
  ON public.posts (author_user_id, created_at DESC)
  WHERE archived_at IS NULL AND status = 'open';

-- ── 8. "Has the viewer already applied?" ─────────────────────────────────────
-- 029 created idx_applications_post_applicant on (post_id, applicant_user_id).
-- The feed asks the mirror question — "which of THESE posts has THIS user
-- applied to" — which needs applicant first.
CREATE INDEX IF NOT EXISTS idx_applications_applicant_post
  ON public.applications (applicant_user_id, post_id);

COMMENT ON INDEX public.idx_posts_feed_live IS
  'Partial index on the real feed predicate (live + open). Stays small as the '
  'archive grows — the primary reason feed cost does not scale with corpus size.';
