-- =============================================================================
-- Migration 031: job_completions table
-- =============================================================================
-- Tracks when a provider marks a job as done and awaits client approval.
-- One active completion record per post at any time (enforced by UNIQUE).
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.job_completions (
  id               UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  post_id          UUID        NOT NULL REFERENCES public.posts(id)         ON DELETE RESTRICT,
  transaction_id   UUID        NOT NULL REFERENCES public.transactions(id)  ON DELETE RESTRICT,
  provider_user_id TEXT        NOT NULL REFERENCES public.users(id),
  client_user_id   TEXT        NOT NULL REFERENCES public.users(id),

  -- pending_approval: client hasn't decided yet
  -- approved:         client approved → payout released
  -- disputed:         client disputed → dispute record created
  status           TEXT        NOT NULL DEFAULT 'pending_approval'
                               CHECK (status IN ('pending_approval','approved','disputed')),

  provider_note    TEXT,                      -- Optional message from provider
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reviewed_at      TIMESTAMPTZ               -- Set when client approves or disputes
);

-- Only one active (pending_approval) completion per post at a time.
CREATE UNIQUE INDEX IF NOT EXISTS uq_job_completions_post_pending
  ON public.job_completions (post_id)
  WHERE status = 'pending_approval';

CREATE INDEX IF NOT EXISTS idx_job_completions_post_id
  ON public.job_completions (post_id);

CREATE INDEX IF NOT EXISTS idx_job_completions_provider
  ON public.job_completions (provider_user_id);

CREATE INDEX IF NOT EXISTS idx_job_completions_client
  ON public.job_completions (client_user_id);

CREATE INDEX IF NOT EXISTS idx_job_completions_status
  ON public.job_completions (status);

ALTER TABLE public.job_completions ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'job_completions_service_role'
      AND tablename  = 'job_completions'
  ) THEN
    CREATE POLICY job_completions_service_role ON public.job_completions
      USING (true) WITH CHECK (true);
  END IF;
END $$;

GRANT ALL ON public.job_completions TO service_role;
