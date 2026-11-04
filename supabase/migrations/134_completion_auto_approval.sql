-- =============================================================================
-- Migration 134: a completion the client never answers approves itself
-- =============================================================================
-- ADDITIVE. Four nullable columns and one partial index; nothing written at
-- apply time, so every existing row keeps auto_approve_at NULL and is never
-- auto-approved.
--
-- Until now a provider who finished a job waited on the client forever: the
-- payout moved only when the client tapped Approve. From now on markComplete
-- stamps a deadline (AUTO_APPROVE_HOURS, 48 by default) and the backend's
-- CompletionAutoApprovalService sweep:
--   * reminds the client halfway through the window and 4 hours before it ends
--     (first_reminder_sent_at / final_reminder_sent_at — each is CLAIMED by a
--     conditional update before the push is sent, so a reminder goes once even
--     if two sweeps overlap);
--   * approves the completion when the deadline passes, through the SAME
--     transition as the client's own Approve (approved_by = 'system').
-- A dispute moves the completion to 'disputed', and every write above is
-- conditional on status = 'pending_approval', so a disputed job is never
-- reminded, approved or paid out by the sweep.
--
-- The deadline is stamped at creation rather than computed from created_at so
-- that changing the window later never shortens a clock that is already
-- running.
--
-- DEPLOY ORDER: apply this BEFORE the backend that writes these columns
-- (markComplete inserts auto_approve_at; approval writes approved_by).
--
-- Rollback (after rolling the backend back):
--   DROP INDEX IF EXISTS public.idx_job_completions_auto_approve_due;
--   ALTER TABLE public.job_completions
--     DROP COLUMN IF EXISTS auto_approve_at,
--     DROP COLUMN IF EXISTS first_reminder_sent_at,
--     DROP COLUMN IF EXISTS final_reminder_sent_at,
--     DROP COLUMN IF EXISTS approved_by;
-- =============================================================================

ALTER TABLE public.job_completions
  ADD COLUMN IF NOT EXISTS auto_approve_at        TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS first_reminder_sent_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS final_reminder_sent_at TIMESTAMPTZ,
  -- Who approved: the client (Approve button) or the system (deadline passed).
  -- NULL on rows approved before this migration.
  ADD COLUMN IF NOT EXISTS approved_by            TEXT
    CHECK (approved_by IS NULL OR approved_by IN ('client', 'system'));

-- The sweep reads exactly this: pending completions that have a deadline.
CREATE INDEX IF NOT EXISTS idx_job_completions_auto_approve_due
  ON public.job_completions (auto_approve_at)
  WHERE status = 'pending_approval' AND auto_approve_at IS NOT NULL;

COMMENT ON COLUMN public.job_completions.auto_approve_at IS
  'When the completion approves itself if the client has neither approved nor disputed. NULL = never (rows before migration 134).';
