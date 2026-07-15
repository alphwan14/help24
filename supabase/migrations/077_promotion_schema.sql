-- =============================================================================
-- Migration 077 — Business Promotion (Phase 1: Featured Listings) core schema
-- =============================================================================
-- Customer-facing product: "Promote Business" (never "Ads"). A provider features
-- one of their existing OFFER posts for a fixed-price, fixed-duration package —
-- no CPC, no CPM, no bidding. Active campaigns are served into discover /
-- search / category / nearby as ordinary marketplace cards with a subtle
-- "Sponsored" badge; promotion is a visibility signal, never a quality override.
--
-- Tables:
--   * promotion_packages  — configurable fixed-price packages. Pricing lives in
--                           the DB, never in code. Public read-only registry
--                           (same trust model as categories, migration 070).
--   * promotion_campaigns — campaign lifecycle + purchase-time package snapshot.
--                           subject_type is polymorphic-ready ('post' today;
--                           'provider' etc. later) so future promotion products
--                           (Spotlight, Hiring Campaigns, Events) reuse this
--                           engine without a rewrite.
--   * promotion_payments  — M-Pesa STK ledger for promotion purchases. This is
--                           PLATFORM REVENUE: deliberately separate from
--                           `transactions`, which is escrow-bound (post_id NOT
--                           NULL, B2C payout semantics, fee tiers).
--   * promotion_settings  — serving/moderation knobs (feed gap, slot caps,
--                           auto-approve, payment TTL) so behaviour is tunable
--                           without a deploy.
--
-- Money: whole KES integers throughout (matches Daraja STK `Amount` and
-- backend/src/mpesa/fee.ts).
--
-- SECURITY: every table is born locked (migration 060 pattern) — RLS pinned
-- TO service_role, zero anon/authenticated grants — EXCEPT promotion_packages,
-- which is a public read-only pricing registry (active rows only). Clients
-- reach campaigns/payments/settings exclusively through the NestJS backend.
-- No S1/bridge prerequisite: nothing here depends on client-side JWT claims.
--
-- SAFE + ADDITIVE: creates new objects only; touches nothing existing.
--
-- Rollback:
--   DROP TABLE IF EXISTS public.promotion_payments;
--   DROP TABLE IF EXISTS public.promotion_campaigns;
--   DROP TABLE IF EXISTS public.promotion_packages;
--   DROP TABLE IF EXISTS public.promotion_settings;
-- =============================================================================

-- ---------------------------------------------------------------------------
-- promotion_packages — the configurable package registry
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.promotion_packages (
  id            TEXT        PRIMARY KEY,          -- stable slug; never rename
  name          TEXT        NOT NULL,
  description   TEXT        NOT NULL DEFAULT '',
  price_kes     INTEGER     CHECK (price_kes IS NULL OR price_kes > 0),
                                                  -- NULL only for custom (admin-priced) packages
  duration_days INTEGER     NOT NULL CHECK (duration_days > 0),
  placements    JSONB       NOT NULL DEFAULT '["discover","search","category","nearby"]'::jsonb,
  is_custom     BOOLEAN     NOT NULL DEFAULT FALSE, -- enterprise: price set per-campaign by admin
  sort          INT         NOT NULL DEFAULT 100,
  active        BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT promotion_packages_priced_or_custom
    CHECK (is_custom OR price_kes IS NOT NULL),
  CONSTRAINT promotion_packages_placements_is_array
    CHECK (jsonb_typeof(placements) = 'array')
);

ALTER TABLE public.promotion_packages ENABLE ROW LEVEL SECURITY;

-- Public pricing registry: clients may read ACTIVE packages (070 pattern).
DROP POLICY IF EXISTS promotion_packages_read ON public.promotion_packages;
CREATE POLICY promotion_packages_read ON public.promotion_packages
  FOR SELECT TO anon, authenticated
  USING (active);

DROP POLICY IF EXISTS promotion_packages_service_role ON public.promotion_packages;
CREATE POLICY promotion_packages_service_role ON public.promotion_packages
  AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

REVOKE ALL    ON public.promotion_packages FROM anon, authenticated;
GRANT  SELECT ON public.promotion_packages TO   anon, authenticated;
GRANT  ALL    ON public.promotion_packages TO   service_role;

-- Seed: launch packages (ON CONFLICT DO NOTHING — re-running never clobbers
-- later admin price edits).
INSERT INTO public.promotion_packages
  (id, name, description, price_kes, duration_days, sort, is_custom) VALUES
  ('starter',    'Starter',    'Get discovered — 3 days of featured visibility.',            300,  3, 10, FALSE),
  ('growth',     'Growth',     'A full week of featured visibility across Help24.',          700,  7, 20, FALSE),
  ('premium',    'Premium',    'Two weeks of maximum featured visibility.',                 1500, 14, 30, FALSE),
  ('enterprise', 'Enterprise', 'Custom promotion for established businesses — contact us.', NULL, 30, 40, TRUE)
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- promotion_campaigns — lifecycle + purchase-time snapshot
-- ---------------------------------------------------------------------------
-- Lifecycle (enforced by the backend state machine; DB stores the state):
--   draft → awaiting_payment → pending_review → active → completed
--     draft / awaiting_payment → expired      (payment window lapsed)
--     pending_review           → rejected     (moderation)
--     active                  ⇄ paused        (owner or admin; resume shifts ends_at)
--     draft/awaiting_payment/pending_review/active/paused → cancelled
--   Terminal: completed, expired, rejected, cancelled.
--
-- post_id is ON DELETE SET NULL so deleting a post never destroys the
-- financial/campaign history; serving simply skips campaigns whose subject is
-- gone (post_title snapshot keeps history readable). Targeting (category, geo,
-- text) always reads the LIVE post so the served card is never stale.
CREATE TABLE IF NOT EXISTS public.promotion_campaigns (
  id               UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  owner_user_id    TEXT        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  subject_type     TEXT        NOT NULL DEFAULT 'post'
                               CHECK (subject_type IN ('post','provider')),
  post_id          UUID        REFERENCES public.posts(id) ON DELETE SET NULL,
  post_title       TEXT,                          -- snapshot for history after post deletion
  package_id       TEXT        NOT NULL REFERENCES public.promotion_packages(id),
  -- Purchase-time snapshot: later package edits never change what was sold.
  package_name     TEXT        NOT NULL,
  price_kes        INTEGER     NOT NULL CHECK (price_kes > 0),
  duration_days    INTEGER     NOT NULL CHECK (duration_days > 0),
  placements       JSONB       NOT NULL DEFAULT '["discover","search","category","nearby"]'::jsonb,
  status           TEXT        NOT NULL DEFAULT 'draft'
                               CHECK (status IN ('draft','awaiting_payment','pending_review',
                                                 'active','paused','rejected','completed',
                                                 'expired','cancelled')),
  starts_at        TIMESTAMPTZ,                   -- set on activation
  ends_at          TIMESTAMPTZ,                   -- set on activation; shifted on resume
  paused_at        TIMESTAMPTZ,
  reviewed_by      TEXT,                          -- admin_users id (moderation)
  reviewed_at      TIMESTAMPTZ,
  rejection_reason TEXT,
  cancelled_at     TIMESTAMPTZ,
  cancel_reason    TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One in-flight campaign per post: no double-promoting the same listing.
CREATE UNIQUE INDEX IF NOT EXISTS uq_promotion_campaigns_live_post
  ON public.promotion_campaigns (post_id)
  WHERE status IN ('awaiting_payment','pending_review','active','paused')
    AND post_id IS NOT NULL;

-- Serving hot path: active campaigns within their window.
CREATE INDEX IF NOT EXISTS idx_promotion_campaigns_serving
  ON public.promotion_campaigns (ends_at)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_promotion_campaigns_owner
  ON public.promotion_campaigns (owner_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_promotion_campaigns_status
  ON public.promotion_campaigns (status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_promotion_campaigns_post
  ON public.promotion_campaigns (post_id);

ALTER TABLE public.promotion_campaigns ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS promotion_campaigns_service_role ON public.promotion_campaigns;
CREATE POLICY promotion_campaigns_service_role ON public.promotion_campaigns
  AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

REVOKE ALL ON public.promotion_campaigns FROM anon, authenticated;
GRANT  ALL ON public.promotion_campaigns TO   service_role;

-- ---------------------------------------------------------------------------
-- promotion_payments — M-Pesa STK ledger for promotion purchases
-- ---------------------------------------------------------------------------
-- Matched to Daraja callbacks by checkout_request_id (same correlation model
-- as `transactions`). No escrow, no payout: money received here is platform
-- revenue. campaign_id is RESTRICT so paid history can never be hard-deleted.
CREATE TABLE IF NOT EXISTS public.promotion_payments (
  id                  UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  campaign_id         UUID        NOT NULL REFERENCES public.promotion_campaigns(id) ON DELETE RESTRICT,
  payer_user_id       TEXT        NOT NULL,
  phone               TEXT        NOT NULL,        -- normalized 254XXXXXXXXX
  amount_kes          INTEGER     NOT NULL CHECK (amount_kes > 0),
  status              TEXT        NOT NULL DEFAULT 'pending'
                                  CHECK (status IN ('pending','paid','failed')),
  checkout_request_id TEXT,
  merchant_request_id TEXT,
  mpesa_receipt       TEXT,
  failure_reason      TEXT,
  paid_at             TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Callback correlation must be unambiguous.
CREATE UNIQUE INDEX IF NOT EXISTS uq_promotion_payments_checkout_request
  ON public.promotion_payments (checkout_request_id)
  WHERE checkout_request_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_promotion_payments_campaign
  ON public.promotion_payments (campaign_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_promotion_payments_payer
  ON public.promotion_payments (payer_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_promotion_payments_status
  ON public.promotion_payments (status);

ALTER TABLE public.promotion_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS promotion_payments_service_role ON public.promotion_payments;
CREATE POLICY promotion_payments_service_role ON public.promotion_payments
  AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

REVOKE ALL ON public.promotion_payments FROM anon, authenticated;
GRANT  ALL ON public.promotion_payments TO   service_role;

-- ---------------------------------------------------------------------------
-- promotion_settings — serving & moderation knobs (tunable without deploy)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.promotion_settings (
  key        TEXT        PRIMARY KEY,
  value      JSONB       NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.promotion_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS promotion_settings_service_role ON public.promotion_settings;
CREATE POLICY promotion_settings_service_role ON public.promotion_settings
  AS PERMISSIVE FOR ALL TO service_role USING (true) WITH CHECK (true);

REVOKE ALL ON public.promotion_settings FROM anon, authenticated;
GRANT  ALL ON public.promotion_settings TO   service_role;

-- Seed defaults (ON CONFLICT DO NOTHING — never clobbers admin tuning).
--   serving.discover_first_after : organic cards before the first sponsored slot
--   serving.discover_gap         : organic cards between sponsored slots (spec: 7–10)
--   serving.*_max_slots          : hard cap per placement request
--   serving.nearby_max_radius_km : promotion never overrides geographic relevance
INSERT INTO public.promotion_settings (key, value) VALUES
  ('serving',    '{"discover_first_after": 7, "discover_gap": 8, "discover_max_slots": 3, "search_max_slots": 2, "category_max_slots": 2, "nearby_max_radius_km": 30}'::jsonb),
  ('moderation', '{"auto_approve": false}'::jsonb),
  ('payment',    '{"awaiting_payment_ttl_hours": 24}'::jsonb)
ON CONFLICT (key) DO NOTHING;
