-- =============================================================================
-- Migration 078 — Business Promotion analytics: raw events + derived daily stats
-- =============================================================================
-- House style (mirrors provider_reputation, migration 055): raw events are the
-- ONLY canonical analytics data; promotion_daily_stats is a DERIVED cache
-- recomputed idempotently by fn_recompute_promotion_daily_stats — no
-- client-maintained counters, no "current + 1" arithmetic, so retried event
-- batches can never double-count a day.
--
-- Event vocabulary (answers "is promoting my business working?"):
--   impression   — sponsored card rendered (placement says where)
--   click        — sponsored card opened (detail sheet)
--   profile_view — provider profile viewed from a sponsored surface
--   phone_tap    — phone number revealed/tapped
--   whatsapp_tap — WhatsApp contact tapped (future surface; vocabulary ready)
--   message      — conversation started from a sponsored surface
--   booking      — reserved for future booking flow
--
-- Day boundaries are Africa/Nairobi (the product's market): a business owner's
-- "today" must match their clock, not UTC.
--
-- SECURITY: born locked (060 pattern) — service_role only. Events are ingested
-- and read exclusively through the backend.
--
-- SAFE + ADDITIVE: new objects only.
--
-- Rollback:
--   DROP FUNCTION IF EXISTS public.fn_recompute_promotion_daily_stats(UUID, DATE);
--   DROP TABLE IF EXISTS public.promotion_daily_stats;
--   DROP TABLE IF EXISTS public.promotion_events;
-- =============================================================================

-- ---------------------------------------------------------------------------
-- promotion_events — raw, append-only analytics events
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.promotion_events (
  id             BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  campaign_id    UUID        NOT NULL REFERENCES public.promotion_campaigns(id) ON DELETE CASCADE,
  event_type     TEXT        NOT NULL
                             CHECK (event_type IN ('impression','click','profile_view',
                                                   'phone_tap','whatsapp_tap','message','booking')),
  placement      TEXT        CHECK (placement IN ('discover','search','category','nearby','profile')),
  viewer_user_id TEXT,                             -- nullable: logged-out browsing counts too
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_promotion_events_campaign_time
  ON public.promotion_events (campaign_id, created_at);

ALTER TABLE public.promotion_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS promotion_events_service_role ON public.promotion_events;
CREATE POLICY promotion_events_service_role ON public.promotion_events
  AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

REVOKE ALL ON public.promotion_events FROM anon, authenticated;
GRANT  ALL ON public.promotion_events TO   service_role;

-- ---------------------------------------------------------------------------
-- promotion_daily_stats — derived per-campaign daily rollup (Nairobi days)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.promotion_daily_stats (
  campaign_id          UUID        NOT NULL REFERENCES public.promotion_campaigns(id) ON DELETE CASCADE,
  day                  DATE        NOT NULL,       -- Africa/Nairobi calendar day
  impressions_discover INTEGER     NOT NULL DEFAULT 0,
  impressions_search   INTEGER     NOT NULL DEFAULT 0,
  impressions_category INTEGER     NOT NULL DEFAULT 0,
  impressions_nearby   INTEGER     NOT NULL DEFAULT 0,
  clicks               INTEGER     NOT NULL DEFAULT 0,
  profile_views        INTEGER     NOT NULL DEFAULT 0,
  phone_taps           INTEGER     NOT NULL DEFAULT 0,
  whatsapp_taps        INTEGER     NOT NULL DEFAULT 0,
  messages             INTEGER     NOT NULL DEFAULT 0,
  bookings             INTEGER     NOT NULL DEFAULT 0,
  recomputed_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (campaign_id, day)
);

ALTER TABLE public.promotion_daily_stats ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS promotion_daily_stats_service_role ON public.promotion_daily_stats;
CREATE POLICY promotion_daily_stats_service_role ON public.promotion_daily_stats
  AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

REVOKE ALL ON public.promotion_daily_stats FROM anon, authenticated;
GRANT  ALL ON public.promotion_daily_stats TO   service_role;

-- ---------------------------------------------------------------------------
-- fn_recompute_promotion_daily_stats — idempotent derive from raw events
-- ---------------------------------------------------------------------------
-- Recomputes ONE (campaign, Nairobi-day) cell from promotion_events. The
-- backend calls this for each (campaign, day) pair touched by an ingested
-- batch. Running it any number of times yields the same row (055 pattern).
CREATE OR REPLACE FUNCTION public.fn_recompute_promotion_daily_stats(
  p_campaign_id UUID,
  p_day         DATE
)
RETURNS void
LANGUAGE plpgsql
AS $func$
DECLARE
  v_start TIMESTAMPTZ;
  v_end   TIMESTAMPTZ;
  v_row   RECORD;
BEGIN
  IF p_campaign_id IS NULL OR p_day IS NULL THEN RETURN; END IF;

  -- Nairobi calendar day → UTC window.
  v_start := p_day::timestamp AT TIME ZONE 'Africa/Nairobi';
  v_end   := (p_day + 1)::timestamp AT TIME ZONE 'Africa/Nairobi';

  SELECT
    COUNT(*) FILTER (WHERE event_type = 'impression' AND placement = 'discover') AS impressions_discover,
    COUNT(*) FILTER (WHERE event_type = 'impression' AND placement = 'search')   AS impressions_search,
    COUNT(*) FILTER (WHERE event_type = 'impression' AND placement = 'category') AS impressions_category,
    COUNT(*) FILTER (WHERE event_type = 'impression' AND placement = 'nearby')   AS impressions_nearby,
    COUNT(*) FILTER (WHERE event_type = 'click')                                 AS clicks,
    COUNT(*) FILTER (WHERE event_type = 'profile_view')                          AS profile_views,
    COUNT(*) FILTER (WHERE event_type = 'phone_tap')                             AS phone_taps,
    COUNT(*) FILTER (WHERE event_type = 'whatsapp_tap')                          AS whatsapp_taps,
    COUNT(*) FILTER (WHERE event_type = 'message')                               AS messages,
    COUNT(*) FILTER (WHERE event_type = 'booking')                               AS bookings
  INTO v_row
  FROM public.promotion_events
  WHERE campaign_id = p_campaign_id
    AND created_at >= v_start
    AND created_at <  v_end;

  INSERT INTO public.promotion_daily_stats AS s (
    campaign_id, day,
    impressions_discover, impressions_search, impressions_category, impressions_nearby,
    clicks, profile_views, phone_taps, whatsapp_taps, messages, bookings, recomputed_at
  ) VALUES (
    p_campaign_id, p_day,
    v_row.impressions_discover, v_row.impressions_search, v_row.impressions_category, v_row.impressions_nearby,
    v_row.clicks, v_row.profile_views, v_row.phone_taps, v_row.whatsapp_taps, v_row.messages, v_row.bookings, NOW()
  )
  ON CONFLICT (campaign_id, day) DO UPDATE SET
    impressions_discover = EXCLUDED.impressions_discover,
    impressions_search   = EXCLUDED.impressions_search,
    impressions_category = EXCLUDED.impressions_category,
    impressions_nearby   = EXCLUDED.impressions_nearby,
    clicks               = EXCLUDED.clicks,
    profile_views        = EXCLUDED.profile_views,
    phone_taps           = EXCLUDED.phone_taps,
    whatsapp_taps        = EXCLUDED.whatsapp_taps,
    messages             = EXCLUDED.messages,
    bookings             = EXCLUDED.bookings,
    recomputed_at        = EXCLUDED.recomputed_at;
END
$func$;
