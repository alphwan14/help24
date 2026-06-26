-- =============================================================================
-- Migration 058: Settlement Ledger Foundation (Phase 3.4A — INERT)
-- =============================================================================
-- Additive ONLY. Creates the append-only `settlements` ledger that explains the
-- existing money state without changing it. This migration:
--   • does NOT modify transactions / escrow / posts
--   • does NOT call any payment API or move money
--   • only CREATEs the settlements table + indexes + RLS
--
-- Uniqueness anchor is transaction_id (a confirmed uuid PK), NOT escrow_id, so
-- the double-pay guard is sound regardless of escrow cardinality/PK.
--
-- Rollback: DROP TABLE public.settlements;
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.settlements (
  id                          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- Money origin (the inbound STK payment). Strong key.
  transaction_id              UUID        NOT NULL REFERENCES public.transactions(id) ON DELETE RESTRICT,
  -- Denormalized holding ref; nullable on purpose (not the uniqueness anchor).
  escrow_id                   UUID,
  -- Denormalized for reporting; TEXT to tolerate the live escrow.post_id type. No FK.
  post_id                     TEXT        NOT NULL,

  direction                   TEXT        NOT NULL
                                CHECK (direction IN ('provider_payout','client_refund','platform_fee')),
  rail                        TEXT        NOT NULL
                                CHECK (rail IN ('mpesa_b2c','manual','internal')),
  amount                      INTEGER     NOT NULL CHECK (amount >= 0),  -- snapshot, units = transactions.amount
  beneficiary_user_id         TEXT,                                      -- NULL for platform_fee

  status                      TEXT        NOT NULL
                                CHECK (status IN (
                                  'initiated','pending','owed','succeeded','failed',
                                  'recorded','completed','voided','retained','refunded')),

  conversation_id             TEXT,
  originator_conversation_id  TEXT,
  mpesa_receipt               TEXT,
  failure_reason              TEXT,
  attempts                    INTEGER     NOT NULL DEFAULT 0,
  last_attempt_at             TIMESTAMPTZ,

  environment                 TEXT        NOT NULL CHECK (environment IN ('sandbox','production')),

  reason_ref_type             TEXT        NOT NULL
                                CHECK (reason_ref_type IN
                                  ('dispute_decision','job_approval','legacy_admin_resolve','backfill')),
  reason_ref_id               TEXT,
  backfill_unverified         BOOLEAN     NOT NULL DEFAULT FALSE,

  created_by                  TEXT        NOT NULL,
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  settled_at                  TIMESTAMPTZ
);

-- ── Double-pay guard ─────────────────────────────────────────────────────────
-- At most ONE active (non-failed/non-voided) leg per (transaction, direction).
-- A failed/voided leg frees the slot so a retry can create a fresh attempt.
CREATE UNIQUE INDEX IF NOT EXISTS uq_settlements_active_leg
  ON public.settlements (transaction_id, direction)
  WHERE status IN ('initiated','pending','owed','succeeded','recorded','completed','retained','refunded');

-- ── Sweep + lookup anchors (used by the 3.4C reconciler; harmless now) ───────
CREATE INDEX IF NOT EXISTS idx_settlements_open
  ON public.settlements (status) WHERE status IN ('initiated','pending','recorded','owed');
CREATE INDEX IF NOT EXISTS idx_settlements_conversation ON public.settlements (conversation_id);
CREATE INDEX IF NOT EXISTS idx_settlements_originator   ON public.settlements (originator_conversation_id);
CREATE INDEX IF NOT EXISTS idx_settlements_transaction  ON public.settlements (transaction_id);
CREATE INDEX IF NOT EXISTS idx_settlements_environment  ON public.settlements (environment);

-- ── RLS: service-role only (mirror escrow/transactions security model) ───────
ALTER TABLE public.settlements ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'settlements_service_role' AND tablename = 'settlements'
  ) THEN
    CREATE POLICY settlements_service_role ON public.settlements
      USING (true) WITH CHECK (true);
  END IF;
END $$;

GRANT SELECT, INSERT, UPDATE ON public.settlements TO service_role;
