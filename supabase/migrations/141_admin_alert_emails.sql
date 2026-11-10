-- =============================================================================
-- Migration 141: email alerts for admins
-- =============================================================================
-- ADDITIVE. Two new tables, nothing written at apply time, nothing else touched.
--
-- Admins had no way of knowing something needed them without signing in to the
-- console. The backend now checks the alert list every five minutes and
-- emails each admin about what is NEW, from "Help24 Admin" <alerts@help24.co.ke>
-- (backend src/admin/alert-emails). Emails name only the kind of alert, how
-- many, and a link to the console: no member names, messages or amounts.
--
--   admin_alert_email_settings  each admin's own choice: which kinds of alert,
--                               and right away / a morning summary / off.
--                               No row = right away, every kind.
--   admin_alert_email_state     what was last announced per alert, so the same
--                               thing is never emailed twice.
--
-- Service role only (the backend). anon and authenticated get nothing.
--
-- Rollback: DROP TABLE IF EXISTS public.admin_alert_email_state;
--           DROP TABLE IF EXISTS public.admin_alert_email_settings;
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.admin_alert_email_settings (
  admin_id        uuid        PRIMARY KEY REFERENCES public.admin_users (id) ON DELETE CASCADE,
  frequency       text        NOT NULL DEFAULT 'instant' CHECK (frequency IN ('instant', 'daily', 'off')),
  categories      text[]      NOT NULL DEFAULT ARRAY['financial', 'trust_safety', 'support', 'marketplace']
                              CHECK (categories <@ ARRAY['financial', 'trust_safety', 'support', 'marketplace']),
  -- The Nairobi date of the last morning summary, so it goes once a day.
  last_digest_on  date,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.admin_alert_email_state (
  alert_id     text        PRIMARY KEY CHECK (alert_id ~ '^[a-z][a-z_]{2,39}$'),
  -- The newest record the alert covered when last seen, and how many.
  latest_at    timestamptz,
  item_count   integer     NOT NULL CHECK (item_count >= 0),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.admin_alert_email_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_alert_email_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.admin_alert_email_settings, public.admin_alert_email_state FROM anon, authenticated;

COMMENT ON TABLE public.admin_alert_email_settings IS
  'Each admin''s alert email choice (migration 141). Service role only.';
COMMENT ON TABLE public.admin_alert_email_state IS
  'What the alert emailer last announced per alert, so nothing is emailed twice (migration 141). Service role only.';
