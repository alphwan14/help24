-- =============================================================================
-- Migration 029: Prevent duplicate applications per post
-- =============================================================================
-- Adds a UNIQUE(post_id, applicant_user_id) constraint to the applications table.
-- First cleans up any existing duplicates by keeping the oldest row (lowest created_at).
-- Safe to run multiple times (constraint creation is guarded by a DO block).
-- =============================================================================

-- Step 1: Remove duplicate applications — keep the oldest per (post_id, applicant_user_id).
-- Uses a self-join: delete row A if a row B exists for the same post+applicant but older.
DELETE FROM public.applications a
USING public.applications b
WHERE a.post_id             = b.post_id
  AND a.applicant_user_id   = b.applicant_user_id
  AND a.applicant_user_id   IS NOT NULL
  AND a.applicant_user_id   != ''
  AND a.created_at          > b.created_at;

-- Step 2: Add the unique constraint (idempotent — skipped if already exists).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM   information_schema.table_constraints
    WHERE  constraint_name = 'uq_applications_post_applicant'
      AND  table_name      = 'applications'
      AND  table_schema    = 'public'
  ) THEN
    ALTER TABLE public.applications
      ADD CONSTRAINT uq_applications_post_applicant
      UNIQUE (post_id, applicant_user_id);
  END IF;
END $$;

-- Step 3: Composite index for hasApplied() and duplicate lookups (covers the constraint too,
-- but an explicit index name makes EXPLAIN plans easier to read).
CREATE INDEX IF NOT EXISTS idx_applications_post_applicant
  ON public.applications (post_id, applicant_user_id);

-- Verify: after running this migration the following query should return 0 rows.
-- SELECT post_id, applicant_user_id, COUNT(*)
-- FROM public.applications
-- WHERE applicant_user_id IS NOT NULL AND applicant_user_id != ''
-- GROUP BY post_id, applicant_user_id
-- HAVING COUNT(*) > 1;
