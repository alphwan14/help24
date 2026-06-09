-- =============================================================================
-- Migration 038: Fix post deletion FK constraints
-- =============================================================================
-- Problem: DELETE FROM posts fails with FK violation from job_completions and
--          disputes (both have ON DELETE RESTRICT).
--
-- Decision: CASCADE for non-financial audit records (job_completions, disputes).
--           transactions and escrow keep RESTRICT — a post with financial
--           activity should never be hard-deleted; archive/soft-delete instead.
--
-- Safety: job_completions are workflow state (not money). disputes are admin
--         records (linked to transactions which still persist). Cascading them
--         is safe.
-- =============================================================================

-- 1. job_completions.post_id: RESTRICT → CASCADE
ALTER TABLE public.job_completions
  DROP CONSTRAINT IF EXISTS job_completions_post_id_fkey;

ALTER TABLE public.job_completions
  ADD CONSTRAINT job_completions_post_id_fkey
    FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE;

-- 2. disputes.post_id: RESTRICT → CASCADE
--    Note: disputes.transaction_id keeps RESTRICT (financial record).
ALTER TABLE public.disputes
  DROP CONSTRAINT IF EXISTS disputes_post_id_fkey;

ALTER TABLE public.disputes
  ADD CONSTRAINT disputes_post_id_fkey
    FOREIGN KEY (post_id) REFERENCES public.posts(id) ON DELETE CASCADE;

-- =============================================================================
-- To archive a completed post without hard deletion:
--   UPDATE public.posts SET status = 'archived' WHERE id = '<uuid>';
-- To hard-delete (only safe when no transactions exist):
--   DELETE FROM public.posts WHERE id = '<uuid>'
--     AND NOT EXISTS (SELECT 1 FROM public.transactions WHERE post_id = '<uuid>');
-- =============================================================================
