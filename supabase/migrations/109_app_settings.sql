-- =============================================================================
-- Migration 109 — app_settings: the client configuration plane
-- =============================================================================
-- ⚠️ NOT YET APPLIED. Written for review; requires explicit approval before it
--    is run against any environment. See docs/phase0-1-implementation-plan.md.
--
-- WHY
-- ---
-- Every operational value the mobile app needs is compiled into the APK today:
-- there is no kill switch, no maintenance mode, and no minimum-version gate
-- anywhere in the system. Between "edit a tuning table in SQL" and "publish a
-- new APK through Play review" there is nothing at all — so a client-side
-- problem has a multi-day exposure window with no mitigation lever.
--
-- This table is that lever. Exactly the same shape and contract as
-- `promotion_settings` (077) and `feed_settings` (090): one JSONB document per
-- concern, merged UNDER compiled defaults by AppConfigService with a per-key
-- type check, so a missing row, a missing key, a typo'd key or a wrong-typed
-- value can never break a client — it silently keeps the compiled default.
--
-- SAFE + ADDITIVE
-- ---------------
--   • One new table. No existing table, column, policy or row is touched.
--   • No data is read, rewritten or migrated.
--   • Applying it changes NO behaviour: it is seeded with the exact values
--     already compiled into backend/src/app-config/client-config.ts and
--     mobile-app/lib/models/remote_config.dart (a golden test asserts the two
--     are byte-equivalent). The table only makes the behaviour editable.
--   • The backend and app already ship WITHOUT this table and behave correctly:
--     AppConfigService treats "relation does not exist" as a normal condition
--     and serves compiled defaults. Applying this is therefore reversible and
--     non-urgent by construction.
--
-- CLIENT ACCESS: none. anon/authenticated get no grants and no policy, so the
-- table is unreachable with the shipped publishable key. Clients read this
-- configuration only through the backend's allowlisted `GET /config`
-- projection, which is built from a typed contract — a row added here that the
-- contract does not name can never reach a device.
--
-- ROLLBACK
-- --------
--   DROP TABLE public.app_settings;
-- Effect: every client immediately falls back to compiled defaults — i.e. the
-- behaviour shipped in the APK. Nothing else references this table; there are
-- no foreign keys, triggers, views or functions depending on it.
--
-- EXPECTED IMPACT
-- ---------------
--   • Storage: 6 rows, a few hundred bytes.
--   • Load: one indexed full-table read per backend replica per 60 s.
--   • Downtime: none. CREATE TABLE IF NOT EXISTS takes no meaningful lock on a
--     table that does not exist, and no other object is altered.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.app_settings (
  key        TEXT        PRIMARY KEY,
  value      JSONB       NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT app_settings_value_is_object
    CHECK (jsonb_typeof(value) = 'object')
);

ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;

-- Service role only. The client-facing projection is the backend's job: it
-- serves a typed allowlist, so operational rows that are not part of the client
-- contract stay server-side even if they are added to this table later.
DROP POLICY IF EXISTS app_settings_service_role ON public.app_settings;
CREATE POLICY app_settings_service_role ON public.app_settings
  TO service_role
  USING (true) WITH CHECK (true);

GRANT ALL ON public.app_settings TO service_role;

-- ── Seed ─────────────────────────────────────────────────────────────────────
-- Byte-equivalent to DEFAULT_CLIENT_CONFIG. Seeding the defaults explicitly
-- (rather than leaving the table empty) makes the operational surface
-- discoverable in the SQL editor: an operator can see every switch that exists
-- and its current value, instead of having to know the key names.
--
-- ON CONFLICT DO NOTHING: re-running never clobbers a live production value.

INSERT INTO public.app_settings (key, value) VALUES

-- Feature kill switches. TRUE = enabled. An absent key or an unreachable
-- backend also means enabled — configuration trouble must never be able to
-- disable commerce. Flip one to false to disable that surface within ~60 s
-- server-side plus the client's own refresh (launch, resume, or 15 min).
('ops.kill_switches', '{
  "payments": true,
  "promotions": true,
  "posting": true,
  "applications": true
}'::jsonb),

-- Planned-downtime notice. Shows an in-app banner; advisory, not a lock.
-- The backend''s own guards remain the real boundary.
('ops.maintenance', '{
  "active": false,
  "message": ""
}'::jsonb),

-- Minimum supported app version. Empty string = no gate.
--   soft → dismissible "update available" banner
--   hard → blocking screen, applied at the next COLD START only, so it can
--          never interrupt a payment already in flight
('ops.min_version', '{
  "soft": "",
  "hard": "",
  "message": "",
  "store_url": ""
}'::jsonb),

-- Product announcement. Dismissal is remembered per id, so reusing an id keeps
-- it dismissed and a new id shows again to everyone.
('ops.announcement', '{
  "id": "",
  "active": false,
  "message": "",
  "url": ""
}'::jsonb),

-- STK payment polling, shared by the escrow and promotion checkout loops.
-- These track Safaricom''s prompt lifetime, which is theirs to change, not
-- ours. Clamped server-side to 2-60 s and 6-120 polls.
('tuning.payments', '{
  "poll_interval_seconds": 5,
  "poll_budget": 24
}'::jsonb),

-- How long a request stays "urgent" after posting. Clamped to 5-1440 minutes.
('tuning.listings', '{
  "urgent_window_minutes": 60
}'::jsonb)

ON CONFLICT (key) DO NOTHING;

-- ── Verification (read-only; run after applying) ─────────────────────────────
--   SELECT key, value FROM public.app_settings ORDER BY key;   -- expect 6 rows
--   -- And from a client's perspective, unchanged behaviour:
--   --   curl https://help24-backend.onrender.com/config
--   -- should return the SAME `version` hash as before this migration was
--   -- applied, because the seed equals the compiled defaults.
