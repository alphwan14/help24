-- =============================================================================
-- Migration 032: disputes table
-- =============================================================================
-- Created when a client disputes a job completion.
-- Admin reviews and resolves via the dashboard.
-- Refunds are processed manually (no automated M-Pesa reversal).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.disputes (
  id                  UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  post_id             UUID        NOT NULL REFERENCES public.posts(id)            ON DELETE RESTRICT,
  transaction_id      UUID        NOT NULL REFERENCES public.transactions(id)     ON DELETE RESTRICT,
  job_completion_id   UUID                    REFERENCES public.job_completions(id) ON DELETE SET NULL,

  raised_by_user_id   TEXT        NOT NULL REFERENCES public.users(id),
  reason              TEXT        NOT NULL,

  -- Lifecycle
  -- open:                 just raised, awaiting admin
  -- under_review:         admin acknowledged, reviewing
  -- resolved_release:     admin decided to release funds to provider
  -- resolved_refund:      admin decided to refund buyer (processed manually)
  -- resolved_partial:     admin split funds between both parties
  status              TEXT        NOT NULL DEFAULT 'open'
                                  CHECK (status IN (
                                    'open',
                                    'under_review',
                                    'resolved_release',
                                    'resolved_refund',
                                    'resolved_partial'
                                  )),

  -- Admin resolution fields
  admin_notes         TEXT,
  resolved_by         TEXT,       -- Admin identifier (email/name)

  -- Amounts for partial split (in KES, stored as integers matching transactions.amount)
  provider_amount     INTEGER     CHECK (provider_amount >= 0),
  buyer_refund        INTEGER     CHECK (buyer_refund >= 0),

  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at         TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_disputes_post_id
  ON public.disputes (post_id);

CREATE INDEX IF NOT EXISTS idx_disputes_transaction_id
  ON public.disputes (transaction_id);

CREATE INDEX IF NOT EXISTS idx_disputes_status
  ON public.disputes (status);

CREATE INDEX IF NOT EXISTS idx_disputes_created_at
  ON public.disputes (created_at DESC);

ALTER TABLE public.disputes ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'disputes_service_role'
      AND tablename  = 'disputes'
  ) THEN
    CREATE POLICY disputes_service_role ON public.disputes
      USING (true) WITH CHECK (true);
  END IF;
END $$;

GRANT ALL ON public.disputes TO service_role;
