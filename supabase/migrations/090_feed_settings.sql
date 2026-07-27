-- =============================================================================
-- Migration 090 — feed_settings: tunable recommendation weights
-- =============================================================================
-- The Discover recommendation engine has ~40 constants (signal weights, decay
-- curves, diversity caps, retrieval limits). Tuning a ranking engine is a
-- continuous activity; shipping an app release — or even a backend deploy —
-- for every weight change makes that activity impossible in practice.
--
-- This table is the tuning surface. Exactly the same shape and contract as
-- `promotion_settings` (077): one JSONB document per concern, merged UNDER
-- code defaults by FeedSettingsService with a per-key type check, so a missing
-- row, a missing key, a typo'd key or a wrong-typed value can never take the
-- feed down — it silently keeps the compiled default.
--
-- SAFE + ADDITIVE: one new table, seeded with the exact values compiled into
-- backend/src/feed/ranking/defaults.ts. Applying this migration therefore
-- changes NO behaviour; it only makes the behaviour editable.
--
-- Clients: no access (server-only, read via service_role).
-- Rollback: DROP TABLE public.feed_settings;   -- engine falls back to defaults
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.feed_settings (
  key        TEXT        PRIMARY KEY,
  value      JSONB       NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT feed_settings_value_is_object
    CHECK (jsonb_typeof(value) = 'object')
);

ALTER TABLE public.feed_settings ENABLE ROW LEVEL SECURITY;

-- No anon/authenticated grants at all: ranking weights are operational config,
-- not public data. Exposing them would hand anyone a map for gaming the feed.
DROP POLICY IF EXISTS feed_settings_service_role ON public.feed_settings;
CREATE POLICY feed_settings_service_role ON public.feed_settings
  TO service_role
  USING (true) WITH CHECK (true);

GRANT ALL ON public.feed_settings TO service_role;

-- ── Seed ─────────────────────────────────────────────────────────────────────
-- ON CONFLICT DO NOTHING: re-running never clobbers a tuned production value.

INSERT INTO public.feed_settings (key, value) VALUES

-- Maximum points each signal can contribute. A signal that returns NULL
-- ("not applicable" — e.g. distance with no viewer location) is removed
-- together with its weight, so absent data never silently flattens a feed.
('weights', '{
  "distance":        30,
  "profession":      25,
  "skills":          10,
  "urgency":         18,
  "freshness":       10,
  "behaviour":       12,
  "reliability":      8,
  "searchHistory":    6,
  "engagement":       5,
  "availability":     5,
  "trust":            5,
  "timeOfDay":        4,
  "ownPost":        -25,
  "alreadyApplied": -30
}'::jsonb),

-- Rational decay 1 / (1 + (km/halfPointKm)^steepness).
-- 1 km → 0.98 | 5 km → 0.84 | 20 km → 0.39 | 100 km → 0.06
-- unknownScore is used when the POST has no coordinates: unknown distance is
-- not evidence of being far away, so it scores neutral rather than zero.
('distance', '{
  "halfPointKm":   15,
  "steepness":     1.5,
  "unknownScore":  0.5
}'::jsonb),

-- Piecewise-linear decay over [hoursSinceCreated, score] anchors, applied while
-- a post is inside its is_urgent window. Past urgent_expires_at the post falls
-- back to enumScores and receives no emergency boost.
('urgency', '{
  "anchors":     [[0, 1.0], [2, 0.85], [6, 0.6], [24, 0.25], [48, 0]],
  "enumScores":  { "urgent": 0.5, "soon": 0.25, "flexible": 0 }
}'::jsonb),

('freshness', '{
  "halfLifeHours": 24
}'::jsonb),

-- Intent over popularity. sat(x,k) = x/(x+k) saturating curves; raw view counts
-- deliberately contribute nothing (a view is not a match). crowdThreshold
-- demotes over-subscribed requests: applicant #31 is a worse match than
-- applicant #3, and this engine optimises for matches.
('engagement', '{
  "applicationsK":    4,
  "savesK":           5,
  "messagesK":        5,
  "applicationsWeight": 0.5,
  "savesWeight":        0.3,
  "messagesWeight":     0.2,
  "crowdThreshold":    10
}'::jsonb),

-- Time-decayed behaviour affinity. Event weights are relative: a hire says far
-- more about intent than an impression.
('behaviour', '{
  "halfLifeDays":     14,
  "lookbackDays":     90,
  "maxKeys":          20,
  "authorFactor":     0.8,
  "searchLookbackDays":  7,
  "searchHalfLifeHours": 48,
  "eventWeights": {
    "hire": 8, "apply": 5, "message": 4, "save": 3, "search": 2,
    "category_open": 1.5, "open": 1, "profile_open": 1,
    "impression": 0.05, "unsave": -3
  }
}'::jsonb),

-- Applies to `offer` posts only (a provider advertising). On requests and jobs
-- the author is the buyer, so their availability is not a relevance signal and
-- the whole signal is skipped.
('availability', '{
  "availableNowScore":   1.0,
  "activeWithin24hScore": 0.5,
  "activeWithin7dScore":  0.35,
  "staleScore":           0.15
}'::jsonb),

-- Reliability blends toward neutral (0.5) until a provider has history, so a
-- new provider is never punished for being new.
('reliability', '{
  "ratingWeight":      0.5,
  "completionWeight":  0.35,
  "disputeWeight":     0.15,
  "confidenceJobs":    5
}'::jsonb),

('trust', '{
  "verifiedWeight": 0.4,
  "businessWeight": 0.2,
  "tierWeight":     0.4,
  "tierScores": {
    "trusted_professional": 1.0,
    "highly_recommended":   0.8,
    "top_rated":            0.6,
    "rising_provider":      0.3,
    "new_provider":         0.0
  }
}'::jsonb),

-- Category ↔ hour-of-day affinity. `hours` are [startInclusive, endExclusive)
-- in the viewer's local time; a window may wrap midnight (e.g. [21, 6]).
-- `baseline` is what an out-of-window post scores — soft, never punitive.
('time_of_day', '{
  "baseline": 0.35,
  "windows": [
    { "hours": [6, 11],  "categories": ["House Cleaning", "Laundry", "Plumbing", "Electrical", "Gardening"] },
    { "hours": [11, 15], "categories": ["Catering", "Delivery Rider", "Driver"] },
    { "hours": [16, 21], "categories": ["Tutoring", "Security Guard", "Babysitting"] },
    { "hours": [21, 6],  "categories": ["Mechanic", "Electrical", "Plumbing", "Security Guard"] }
  ]
}'::jsonb),

-- Composition caps. Relaxation order is fixed in code (category → type →
-- consecutive author → per-author cap) so a thin feed degrades to pure score
-- order instead of returning a short page.
('diversity', '{
  "maxConsecutiveSameAuthor":   1,
  "maxPerAuthorPerPage":        2,
  "maxConsecutiveSameCategory": 2,
  "maxConsecutiveSameType":     3
}'::jsonb),

-- Retrieval bounds. These are the numbers that keep per-request cost constant
-- as the corpus grows: cost is O(maxCandidates), never O(posts).
('retrieval', '{
  "poolLimit":       150,
  "maxCandidates":   400,
  "radiusKm":        60,
  "pageSize":        20,
  "maxPageSize":     50,
  "rotationBucketMinutes": 10
}'::jsonb)

ON CONFLICT (key) DO NOTHING;

COMMENT ON TABLE public.feed_settings IS
  'Discover recommendation engine tuning. Merged UNDER backend defaults by '
  'FeedSettingsService (60s cache). A missing key keeps the compiled default; '
  'a wrong-typed value is ignored. Server-only — never exposed to clients.';
