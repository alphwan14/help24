-- =============================================================================
-- Migration 049: dispute_decisions — IMMUTABLE arbitration audit log
-- =============================================================================
-- The legally/financially significant record. Every admin (or system) ruling on
-- a dispute writes exactly one append-only row here. Rows can NEVER be updated
-- or deleted — a database-level trigger enforces this so the audit trail is
-- tamper-evident (fintech requirement). The mutable `disputes` row reflects the
-- latest state; this table is the permanent ledger of who decided what and why.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.dispute_decisions (
  id                   UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  dispute_id           UUID        NOT NULL REFERENCES public.disputes(id) ON DELETE RESTRICT,

  -- Accountable admin. NULL only for system-generated decisions (auto-escalate),
  -- in which case decided_by_system = true.
  admin_id             UUID        REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  decided_by_system    BOOLEAN     NOT NULL DEFAULT FALSE,

  decision_type        TEXT        NOT NULL CHECK (decision_type IN (
                                     'FULL_REFUND', 'FULL_RELEASE', 'PARTIAL_SPLIT', 'ESCALATE'
                                   )),

  -- Amounts in KES integers (match transactions.amount). NULL for ESCALATE.
  provider_amount      INTEGER     CHECK (provider_amount      IS NULL OR provider_amount      >= 0),
  client_refund_amount INTEGER     CHECK (client_refund_amount IS NULL OR client_refund_amount >= 0),

  reasoning            TEXT        NOT NULL,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- A human decision must name an admin; a system decision must not.
  CONSTRAINT dispute_decisions_actor_present CHECK (
    (decided_by_system = TRUE  AND admin_id IS NULL) OR
    (decided_by_system = FALSE AND admin_id IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_dispute_decisions_dispute ON public.dispute_decisions (dispute_id, created_at);
CREATE INDEX IF NOT EXISTS idx_dispute_decisions_admin   ON public.dispute_decisions (admin_id);

-- ── Immutability enforcement ────────────────────────────────────────────────
-- Block UPDATE and DELETE at the row level. Inserts are allowed; nothing else.
CREATE OR REPLACE FUNCTION public.fn_block_decision_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'dispute_decisions is an immutable audit log — % is not permitted', TG_OP
    USING ERRCODE = 'restrict_violation';
END $$;

DROP TRIGGER IF EXISTS trg_dispute_decisions_immutable ON public.dispute_decisions;
CREATE TRIGGER trg_dispute_decisions_immutable
  BEFORE UPDATE OR DELETE ON public.dispute_decisions
  FOR EACH ROW EXECUTE FUNCTION public.fn_block_decision_mutation();

ALTER TABLE public.dispute_decisions ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'dispute_decisions_service_role' AND tablename = 'dispute_decisions'
  ) THEN
    CREATE POLICY dispute_decisions_service_role ON public.dispute_decisions
      USING (true) WITH CHECK (true);
  END IF;
END $$;

-- Grant INSERT/SELECT only — never UPDATE/DELETE — to reinforce immutability
-- even if the trigger were ever dropped.
GRANT SELECT, INSERT ON public.dispute_decisions TO service_role;
