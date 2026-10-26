-- =============================================================================
-- Migration 126: which app version each member is on
-- =============================================================================
-- ADDITIVE. Two nullable columns on public.users; no data written at apply.
--
-- The app (1.0.6+) writes its own versionName once per session, through the
-- existing users_update_own policy (id = the JWT's user_id), in an update of
-- its own — separate from the presence heartbeat, so a failure here can never
-- stop last_seen being written.
--
-- The dashboard uses it to show the versions in use among recently active
-- members, and how many people raising the REQUIRED version would block,
-- before anyone raises it (App controls).
--
-- Older apps never write it: NULL means "1.0.5 or older, or not opened since".
--
-- Rollback: ALTER TABLE public.users DROP COLUMN app_version, DROP COLUMN app_version_seen_at;
-- =============================================================================

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS app_version text
    CHECK (app_version IS NULL OR app_version ~ '^\d{1,4}\.\d{1,4}\.\d{1,4}$'),
  ADD COLUMN IF NOT EXISTS app_version_seen_at timestamptz;

COMMENT ON COLUMN public.users.app_version IS
  'versionName the member''s app last reported (1.0.6+). NULL = older app or never reported.';
