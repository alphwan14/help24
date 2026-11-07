-- =============================================================================
-- Migration 137: first-party website events (is the provider card shared?)
-- =============================================================================
-- ADDITIVE. One table, one write function the website calls, one read function
-- the admin dashboard calls. Independent of 135/136.
--
-- WHY FIRST-PARTY
--   The provider card (Phase A, docs/provider-card.md) is judged on whether
--   providers hand it out. help24.co.ke already emits the events
--   (provider_card_open, provider_card_open_app, qr_scan, …) into
--   window.dataLayer, but nothing collected them. Vercel's free plan counts page
--   views only; Google Analytics would put a third-party script and cookies on
--   the page (a consent notice under the Data Protection Act 2019). These
--   events go to Help24's own database instead: no cookies, no IP address, no
--   device identifier — the event, the channel (QR or link), a coarse platform
--   and browser, the country Vercel resolves, and for card events the provider
--   whose card it was (already in the URL; it never leaves Help24).
--
-- HOW IT IS WRITTEN
--   The website's /api/e route calls record_site_event() with the publishable
--   key. The function is the only door: it accepts known events and short,
--   shaped fields, and drops anything else silently (a beacon has nobody to
--   tell). The table itself is closed to clients.
--
-- HOW IT IS READ
--   admin_provider_card_stats(p_days) — service role only (the admin
--   dashboard's Partners → Provider cards page).
--
-- Rollback:
--   DROP FUNCTION IF EXISTS public.admin_provider_card_stats(integer),
--                           public.record_site_event(text, text, text, text, text, text, text, text);
--   DROP TABLE IF EXISTS public.site_events;
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.site_events (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event       TEXT NOT NULL CHECK (event IN (
                'provider_card_open', 'provider_card_open_app', 'qr_scan',
                'download_click', 'checksum_copy', 'agent_open_app')),
  provider_id TEXT,                       -- card events only
  source      TEXT CHECK (source IS NULL OR source IN ('qr', 'link')),
  platform    TEXT CHECK (platform IS NULL OR platform IN ('android', 'ios', 'desktop')),
  browser     TEXT CHECK (browser IS NULL OR browser IN ('chrome', 'safari', 'firefox', 'edge', 'opera', 'other')),
  app_version TEXT,                       -- the APK version the site offered
  country     TEXT,                       -- ISO 3166-1 alpha-2, from Vercel
  path        TEXT,                       -- pathname only, never the query string
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.site_events IS
  'First-party website events (no cookies, no IP, no device id). Written only through record_site_event(). Migration 137.';

CREATE INDEX IF NOT EXISTS idx_site_events_event_time ON public.site_events (event, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_site_events_provider ON public.site_events (provider_id, created_at DESC)
  WHERE provider_id IS NOT NULL;

ALTER TABLE public.site_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.site_events FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.site_events TO service_role;

-- The website's door. Returns true when the event was kept.
CREATE OR REPLACE FUNCTION public.record_site_event(
  p_event       text,
  p_provider_id text,
  p_source      text,
  p_platform    text,
  p_browser     text,
  p_app_version text,
  p_country     text,
  p_path        text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_provider text := nullif(btrim(coalesce(p_provider_id, '')), '');
BEGIN
  IF p_event NOT IN ('provider_card_open', 'provider_card_open_app', 'qr_scan',
                     'download_click', 'checksum_copy', 'agent_open_app') THEN
    RETURN false;
  END IF;

  -- A card event names a real member, or it is not kept: a beacon anyone can
  -- send must not be able to fill the table with invented providers.
  IF p_event IN ('provider_card_open', 'provider_card_open_app') THEN
    IF v_provider IS NULL OR v_provider !~ '^[A-Za-z0-9]{20,128}$'
       OR NOT EXISTS (SELECT 1 FROM public.users WHERE id = v_provider) THEN
      RETURN false;
    END IF;
  ELSE
    v_provider := NULL;
  END IF;

  INSERT INTO public.site_events (event, provider_id, source, platform, browser, app_version, country, path)
  VALUES (
    p_event,
    v_provider,
    CASE WHEN p_source IN ('qr', 'link') THEN p_source END,
    CASE WHEN p_platform IN ('android', 'ios', 'desktop') THEN p_platform END,
    CASE WHEN p_browser IN ('chrome', 'safari', 'firefox', 'edge', 'opera', 'other') THEN p_browser END,
    CASE WHEN p_app_version ~ '^[0-9]+\.[0-9]+\.[0-9]+([+.-][A-Za-z0-9.]+)?$' THEN left(p_app_version, 32) END,
    CASE WHEN p_country ~ '^[A-Z]{2}$' THEN p_country END,
    CASE WHEN p_path ~ '^/[A-Za-z0-9/_.-]{0,200}$' THEN p_path END
  );
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.record_site_event(text, text, text, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_site_event(text, text, text, text, text, text, text, text) TO anon, authenticated, service_role;

-- What the dashboard shows: is the card being handed out, and does it bring
-- people into the app?
CREATE OR REPLACE FUNCTION public.admin_provider_card_stats(p_days integer DEFAULT 30)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH w AS (
    SELECT * FROM public.site_events
     WHERE created_at >= now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)))
  ), opens AS (
    SELECT * FROM w WHERE event = 'provider_card_open'
  )
  SELECT jsonb_build_object(
    'days',               greatest(1, least(coalesce(p_days, 30), 365)),
    'opens',              (SELECT count(*) FROM opens),
    'opens_qr',           (SELECT count(*) FROM opens WHERE source = 'qr'),
    'opens_link',         (SELECT count(*) FROM opens WHERE source = 'link'),
    'open_app_taps',      (SELECT count(*) FROM w WHERE event = 'provider_card_open_app'),
    'download_clicks',    (SELECT count(*) FROM w WHERE event = 'download_click'),
    'providers_shared',   (SELECT count(DISTINCT provider_id) FROM opens),
    'by_day', coalesce((
      SELECT jsonb_agg(jsonb_build_object('day', d, 'opens', n) ORDER BY d)
        FROM (SELECT (created_at AT TIME ZONE 'Africa/Nairobi')::date AS d, count(*) AS n
                FROM opens GROUP BY 1) x), '[]'::jsonb),
    'by_platform', coalesce((
      SELECT jsonb_object_agg(coalesce(platform, 'unknown'), n)
        FROM (SELECT platform, count(*) AS n FROM opens GROUP BY 1) x), '{}'::jsonb),
    'top_providers', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'provider_id', t.provider_id, 'name', u.name, 'profession', u.profession,
               'opens', t.opens, 'qr', t.qr, 'open_app', t.open_app, 'last_at', t.last_at)
             ORDER BY t.opens DESC, t.last_at DESC)
        FROM (
          SELECT provider_id,
                 count(*) FILTER (WHERE event = 'provider_card_open')                   AS opens,
                 count(*) FILTER (WHERE event = 'provider_card_open' AND source = 'qr') AS qr,
                 count(*) FILTER (WHERE event = 'provider_card_open_app')               AS open_app,
                 max(created_at)                                                        AS last_at
            FROM w
           WHERE provider_id IS NOT NULL
           GROUP BY provider_id
           ORDER BY 2 DESC, 5 DESC
           LIMIT 20
        ) t
        LEFT JOIN public.users u ON u.id = t.provider_id), '[]'::jsonb),
    'first_event_at', (SELECT min(created_at) FROM public.site_events)
  )
$$;

REVOKE ALL ON FUNCTION public.admin_provider_card_stats(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_provider_card_stats(integer) TO service_role;
