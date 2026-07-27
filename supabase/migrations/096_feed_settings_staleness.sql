-- =============================================================================
-- Migration 096 — staleness penalty + decaying urgency enum
-- =============================================================================
-- Three defects showed up the first time the engine was pointed at a real
-- corpus from a real distance. A viewer in MOMBASA got, as their #1
-- recommendation, an "urgent" request in NAIROBI posted five months earlier.
-- Each cause was independently defensible and together they were absurd:
--
--   1. DISTANCE — a post with no coordinates scored a flat 0.5, i.e. "treat it
--      as 15 km away". Reasonable in a Nairobi-centric corpus. For a viewer in
--      Mombasa, every post WITH coordinates is ~440 km away and scores ~0.006,
--      so any post MISSING coordinates collected 15 of 30 points and won
--      outright. "Don't punish missing data" had become "reward missing data".
--      Fixed in code: unknown distance is now scored at the MEDIAN distance of
--      the candidates that do have coordinates, so "neutral" means typical for
--      this feed. No setting change.
--
--   2. URGENCY — past its expiry window a post fell back to a FLAT enum score,
--      so `urgency='urgent'` was worth 9 of 18 points forever. The architecture
--      doc had always specified "urgent 0.5 x freshness"; the code never
--      multiplied. Fixed in code; `enumHalfLifeHours` below makes the decay
--      tunable.
--
--   3. STALENESS — nothing in the engine knew that a five-month-old OPEN
--      request in a same-day services marketplace has been resolved offline.
--      Freshness only declines to award its 10 points; it cannot say "dead".
--      In a thin feed, where most signals sit at neutral, an abandoned post
--      drifts to the top on the absence of competition. New penalty signal.
--
-- SAFE + ADDITIVE. Existing tuned values are never overwritten: each statement
-- only writes a key that is currently ABSENT. Re-running is a no-op.
--
-- Not required for the fixes to work — the backend falls back to the compiled
-- defaults in ranking/defaults.ts, which this file mirrors exactly. Apply it so
-- the values stay tunable from SQL.
--
-- Rollback:
--   update public.feed_settings set value = value - 'staleness' where key = 'weights';
--   delete from public.feed_settings where key = 'staleness';
--   update public.feed_settings set value = value - 'enumHalfLifeHours' where key = 'urgency';
-- =============================================================================

-- ── 1. staleness weight ─────────────────────────────────────────────────────
-- Sized just under alreadyApplied (-30) and just below ownPost (-25): a post
-- that is probably already resolved is nearly as useless as one you already
-- answered, but it is a GUESS about the world rather than a fact about the
-- viewer, so it demotes slightly less hard.
UPDATE public.feed_settings
   SET value = jsonb_set(value, '{staleness}', '-22'::jsonb, true),
       updated_at = NOW()
 WHERE key = 'weights'
   AND NOT (value ? 'staleness');

-- ── 2. staleness curve ──────────────────────────────────────────────────────
-- No penalty at all for the first 30 days; ramps linearly to full penalty at
-- 90 days. A ramp rather than a cliff, so a post does not visibly fall off the
-- feed overnight — from the outside that reads as a bug.
INSERT INTO public.feed_settings (key, value) VALUES
('staleness', '{
  "staleAfterDays": 30,
  "deadAfterDays":  90
}'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- ── 3. urgency enum decay ───────────────────────────────────────────────────
-- 72 h half-life: a request marked urgent today keeps its modest edge, one
-- marked urgent last season keeps nothing. Applies only to the enum fallback —
-- a LIVE emergency window still uses the `anchors` curve unchanged.
UPDATE public.feed_settings
   SET value = jsonb_set(value, '{enumHalfLifeHours}', '72'::jsonb, true),
       updated_at = NOW()
 WHERE key = 'urgency'
   AND NOT (value ? 'enumHalfLifeHours');

-- ── Verify ──────────────────────────────────────────────────────────────────
--   select value -> 'staleness'         from public.feed_settings where key = 'weights';  -- -22
--   select value                        from public.feed_settings where key = 'staleness';
--   select value -> 'enumHalfLifeHours' from public.feed_settings where key = 'urgency';  -- 72
