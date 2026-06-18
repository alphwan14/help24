-- =============================================================================
-- Migration 055: provider_reputation + fn_recompute_provider_reputation + backfill
-- =============================================================================
-- The SINGLE reputation authority. Every metric is DERIVED (recomputed) from
-- canonical tables only — reviews, job_completions, disputes, posts. There are
-- NO client-maintained counters and NO incremental "current + 1" arithmetic.
--
-- fn_recompute_provider_reputation(provider_id) is IDEMPOTENT: it reads the
-- current canonical state and UPSERTs the derived row, so running it any number
-- of times always produces the same result for the same underlying data.
-- Additive only — no destructive changes.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.provider_reputation (
  provider_id      TEXT             PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  avg_rating       DOUBLE PRECISION NOT NULL DEFAULT 0,   -- raw mean of visible reviews
  bayesian_rating  DOUBLE PRECISION NOT NULL DEFAULT 0,   -- small-sample-corrected score
  total_reviews    INTEGER          NOT NULL DEFAULT 0,
  completed_jobs   INTEGER          NOT NULL DEFAULT 0,
  disputed_jobs    INTEGER          NOT NULL DEFAULT 0,
  open_disputes    INTEGER          NOT NULL DEFAULT 0,
  completion_rate  DOUBLE PRECISION NOT NULL DEFAULT 0,   -- 0..1
  dispute_rate     DOUBLE PRECISION NOT NULL DEFAULT 0,   -- 0..1
  repeat_clients   INTEGER          NOT NULL DEFAULT 0,
  tier             TEXT             NOT NULL DEFAULT 'new_provider'
                                      CHECK (tier IN ('new_provider','rising_provider','top_rated',
                                                      'highly_recommended','trusted_professional')),
  last_active_at   TIMESTAMPTZ,
  recomputed_at    TIMESTAMPTZ      NOT NULL DEFAULT NOW()
);

ALTER TABLE public.provider_reputation ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'provider_reputation_service_role' AND tablename = 'provider_reputation'
  ) THEN
    CREATE POLICY provider_reputation_service_role ON public.provider_reputation
      USING (true) WITH CHECK (true);
  END IF;
END $$;

GRANT ALL ON public.provider_reputation TO service_role;

-- ── Idempotent recompute: derive EVERY metric from canonical data ────────────
-- Sources: reviews, job_completions, disputes, posts. No counters, no deltas.
CREATE OR REPLACE FUNCTION public.fn_recompute_provider_reputation(p_provider_id TEXT)
RETURNS void
LANGUAGE plpgsql
AS $func$
DECLARE
  C  CONSTANT DOUBLE PRECISION := 10.0;  -- Bayesian confidence weight
  m  CONSTANT DOUBLE PRECISION := 4.5;   -- Bayesian prior mean
  v_total_reviews   INTEGER;
  v_avg_rating      DOUBLE PRECISION;
  v_bayesian        DOUBLE PRECISION;
  v_completed       INTEGER;
  v_disputed        INTEGER;
  v_open_disputes   INTEGER;
  v_concluded       INTEGER;
  v_completion_rate DOUBLE PRECISION;
  v_dispute_rate    DOUBLE PRECISION;
  v_repeat_clients  INTEGER;
  v_last_active     TIMESTAMPTZ;
  v_tier            TEXT;
BEGIN
  IF p_provider_id IS NULL OR p_provider_id = '' THEN RETURN; END IF;

  -- Reviews (visible only)
  SELECT COUNT(*), COALESCE(AVG(rating), 0)
    INTO v_total_reviews, v_avg_rating
    FROM public.reviews
    WHERE provider_id = p_provider_id AND status = 'visible';

  v_bayesian := CASE
    WHEN v_total_reviews = 0 THEN 0
    ELSE ((C * m) + (v_avg_rating * v_total_reviews)) / (C + v_total_reviews)
  END;

  -- Completed jobs = approved completions on posts where this provider was selected
  SELECT COUNT(DISTINCT jc.post_id)
    INTO v_completed
    FROM public.job_completions jc
    JOIN public.posts p ON p.id = jc.post_id
    WHERE p.selected_provider_id = p_provider_id AND jc.status = 'approved';

  -- Disputed jobs = distinct provider-selected posts that ever had a dispute
  SELECT COUNT(DISTINCT d.post_id)
    INTO v_disputed
    FROM public.disputes d
    JOIN public.posts p ON p.id = d.post_id
    WHERE p.selected_provider_id = p_provider_id;

  -- Open disputes = non-terminal disputes for this provider
  SELECT COUNT(*)
    INTO v_open_disputes
    FROM public.disputes d
    JOIN public.posts p ON p.id = d.post_id
    WHERE p.selected_provider_id = p_provider_id
      AND d.status NOT IN ('resolved','resolved_release','resolved_refund','resolved_partial','merged');

  -- Concluded jobs = provider-selected posts that reached a terminal post status
  SELECT COUNT(*)
    INTO v_concluded
    FROM public.posts p
    WHERE p.selected_provider_id = p_provider_id
      AND p.status IN ('completed','cancelled');

  v_completion_rate := CASE WHEN v_concluded = 0 THEN 0
                            ELSE LEAST(1.0, v_completed::DOUBLE PRECISION / v_concluded) END;
  v_dispute_rate    := CASE WHEN v_concluded = 0 THEN 0
                            ELSE LEAST(1.0, v_disputed::DOUBLE PRECISION / v_concluded) END;

  -- Repeat clients = distinct clients with >1 approved-completed job from this provider
  SELECT COUNT(*)
    INTO v_repeat_clients
    FROM (
      SELECT p.author_user_id
        FROM public.job_completions jc
        JOIN public.posts p ON p.id = jc.post_id
        WHERE p.selected_provider_id = p_provider_id AND jc.status = 'approved'
        GROUP BY p.author_user_id
        HAVING COUNT(*) > 1
    ) repeats;

  -- Last active = most recent approved completion
  SELECT MAX(jc.created_at)
    INTO v_last_active
    FROM public.job_completions jc
    JOIN public.posts p ON p.id = jc.post_id
    WHERE p.selected_provider_id = p_provider_id AND jc.status = 'approved';

  -- Derived tier. Rating-gated top tiers require real reviews; 'rising_provider'
  -- is experience-based so proven-but-unrated providers escape 'new_provider'.
  v_tier := CASE
    WHEN v_total_reviews >= 10 AND v_completed >= 50 AND v_bayesian >= 4.8
         AND v_dispute_rate <= 0.03 AND v_completion_rate >= 0.95 THEN 'trusted_professional'
    WHEN v_total_reviews >= 5  AND v_completed >= 25 AND v_bayesian >= 4.7
         AND v_completion_rate >= 0.90 AND v_repeat_clients >= 3 THEN 'highly_recommended'
    WHEN v_total_reviews >= 3  AND v_completed >= 10 AND v_bayesian >= 4.6
         AND v_dispute_rate <= 0.07 THEN 'top_rated'
    WHEN v_completed >= 3 AND v_dispute_rate <= 0.10 THEN 'rising_provider'
    ELSE 'new_provider'
  END;

  INSERT INTO public.provider_reputation AS pr (
    provider_id, avg_rating, bayesian_rating, total_reviews, completed_jobs,
    disputed_jobs, open_disputes, completion_rate, dispute_rate, repeat_clients,
    tier, last_active_at, recomputed_at
  ) VALUES (
    p_provider_id, v_avg_rating, v_bayesian, v_total_reviews, v_completed,
    v_disputed, v_open_disputes, v_completion_rate, v_dispute_rate, v_repeat_clients,
    v_tier, v_last_active, NOW()
  )
  ON CONFLICT (provider_id) DO UPDATE SET
    avg_rating      = EXCLUDED.avg_rating,
    bayesian_rating = EXCLUDED.bayesian_rating,
    total_reviews   = EXCLUDED.total_reviews,
    completed_jobs  = EXCLUDED.completed_jobs,
    disputed_jobs   = EXCLUDED.disputed_jobs,
    open_disputes   = EXCLUDED.open_disputes,
    completion_rate = EXCLUDED.completion_rate,
    dispute_rate    = EXCLUDED.dispute_rate,
    repeat_clients  = EXCLUDED.repeat_clients,
    tier            = EXCLUDED.tier,
    last_active_at  = EXCLUDED.last_active_at,
    recomputed_at   = EXCLUDED.recomputed_at;
END
$func$;

-- ── Backfill: recompute every existing provider from canonical data ──────────
-- Safe + idempotent: revives completed-jobs + dispute metrics immediately, with
-- zero reviews (none exist yet — acceptable per spec).
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT DISTINCT p.selected_provider_id AS pid
      FROM public.posts p
      JOIN public.users u ON u.id = p.selected_provider_id  -- only real users (FK-safe)
      WHERE p.selected_provider_id IS NOT NULL AND p.selected_provider_id <> ''
  LOOP
    PERFORM public.fn_recompute_provider_reputation(r.pid);
  END LOOP;
END $$;
