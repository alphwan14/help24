-- =============================================================================
-- Migration 046: extend disputes for the Arbitration Centre
-- =============================================================================
-- Grows the existing `disputes` table (migration 032) into a full arbitration
-- case record WITHOUT breaking the current flow (jobs.service.dispute, the
-- legacy /admin/disputes/resolve endpoint).
--
-- Adds: priority, admin assignment + case lock, SLA timestamps, duplicate merge
-- pointer, and expands the status lifecycle to the production model:
--   open → reviewing → resolved | escalated   (+ merged)
-- Legacy statuses (under_review, resolved_release/refund/partial) are RETAINED
-- in the CHECK so existing rows and the legacy resolver keep working.
-- =============================================================================

-- ── New columns ─────────────────────────────────────────────────────────────
ALTER TABLE public.disputes
  ADD COLUMN IF NOT EXISTS priority            TEXT,
  ADD COLUMN IF NOT EXISTS assigned_admin_id   UUID,
  ADD COLUMN IF NOT EXISTS assigned_at         TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS first_response_at   TIMESTAMPTZ,   -- SLA: first admin action
  ADD COLUMN IF NOT EXISTS escalated_at        TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS merged_into_dispute_id UUID,
  ADD COLUMN IF NOT EXISTS raised_by_role      TEXT;          -- 'client' | 'provider'

-- priority: backfill existing rows to 'medium', then enforce NOT NULL + CHECK.
UPDATE public.disputes SET priority = 'medium' WHERE priority IS NULL;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_schema='public' AND table_name='disputes'
      AND constraint_name='disputes_priority_check'
  ) THEN
    ALTER TABLE public.disputes
      ADD CONSTRAINT disputes_priority_check
      CHECK (priority IN ('low','medium','high','critical'));
  END IF;
END $$;

ALTER TABLE public.disputes ALTER COLUMN priority SET DEFAULT 'medium';
ALTER TABLE public.disputes ALTER COLUMN priority SET NOT NULL;

-- raised_by_role check (nullable — legacy rows have no role recorded).
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_schema='public' AND table_name='disputes'
      AND constraint_name='disputes_raised_by_role_check'
  ) THEN
    ALTER TABLE public.disputes
      ADD CONSTRAINT disputes_raised_by_role_check
      CHECK (raised_by_role IS NULL OR raised_by_role IN ('client','provider'));
  END IF;
END $$;

-- ── Foreign keys for the new relationship columns ───────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_schema='public' AND table_name='disputes'
      AND constraint_name='disputes_assigned_admin_fkey'
  ) THEN
    ALTER TABLE public.disputes
      ADD CONSTRAINT disputes_assigned_admin_fkey
      FOREIGN KEY (assigned_admin_id) REFERENCES public.admin_users(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_schema='public' AND table_name='disputes'
      AND constraint_name='disputes_merged_into_fkey'
  ) THEN
    ALTER TABLE public.disputes
      ADD CONSTRAINT disputes_merged_into_fkey
      FOREIGN KEY (merged_into_dispute_id) REFERENCES public.disputes(id) ON DELETE SET NULL;
  END IF;
END $$;

-- ── Expand the status CHECK (retain legacy values for backward compatibility) ─
DO $$
DECLARE ck_name TEXT;
BEGIN
  SELECT tc.constraint_name INTO ck_name
    FROM information_schema.table_constraints tc
   WHERE tc.table_schema='public' AND tc.table_name='disputes'
     AND tc.constraint_type='CHECK' AND tc.constraint_name ILIKE '%status%'
   LIMIT 1;
  IF ck_name IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.disputes DROP CONSTRAINT ' || quote_ident(ck_name);
  END IF;
END $$;

ALTER TABLE public.disputes
  ADD CONSTRAINT disputes_status_check
  CHECK (status IN (
    -- production lifecycle
    'open', 'reviewing', 'resolved', 'escalated', 'merged',
    -- legacy (migration 032 / legacy resolver) — kept so old rows stay valid
    'under_review', 'resolved_release', 'resolved_refund', 'resolved_partial'
  ));

-- ── Indexes for dashboard filtering / SLA / assignment ──────────────────────
CREATE INDEX IF NOT EXISTS idx_disputes_priority      ON public.disputes (priority);
CREATE INDEX IF NOT EXISTS idx_disputes_assigned      ON public.disputes (assigned_admin_id);
CREATE INDEX IF NOT EXISTS idx_disputes_open_age      ON public.disputes (created_at)
  WHERE status IN ('open','reviewing','under_review');

COMMENT ON COLUMN public.disputes.assigned_admin_id IS
  'Admin who claimed the case. Acts as a soft lock: only this admin (or a super_admin) may decide.';
COMMENT ON COLUMN public.disputes.merged_into_dispute_id IS
  'Set when this dispute was a duplicate merged into a canonical case (status=merged).';
