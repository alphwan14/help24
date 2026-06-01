-- =============================================================================
-- Migration 030: Escrow lifecycle schema fixes
-- =============================================================================
-- 1. Fix escrow.provider_id: UUID FK → providers is wrong; providers are users.
--    Change to TEXT referencing users(id) so releasePayout() works correctly.
-- 2. Extend transaction.status with 'disputed' and 'refunded'.
-- 3. Extend escrow.status with 'disputed' and 'refunded'.
-- 4. Add posts.status column for explicit lifecycle tracking.
-- 5. Hard-block self-application (applicant cannot be post author).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Fix escrow.provider_id type
-- ---------------------------------------------------------------------------
-- Drop the old FK constraint pointing to providers(id), then re-add as TEXT.

DO $$
DECLARE
  fk_name TEXT;
BEGIN
  -- Find the FK constraint name (may vary across environments)
  SELECT tc.constraint_name
    INTO fk_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
   WHERE tc.table_schema   = 'public'
     AND tc.table_name     = 'escrow'
     AND tc.constraint_type = 'FOREIGN KEY'
     AND kcu.column_name   = 'provider_id'
   LIMIT 1;

  IF fk_name IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.escrow DROP CONSTRAINT ' || quote_ident(fk_name);
    RAISE NOTICE 'escrow: dropped FK constraint % on provider_id', fk_name;
  END IF;
END $$;

-- Change column type from UUID to TEXT (existing NULL values are unaffected).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'escrow'
      AND column_name  = 'provider_id'
      AND data_type    = 'uuid'
  ) THEN
    -- Cast existing UUIDs to text (they will be NULL in practice since the FK
    -- was broken, so this is safe).
    ALTER TABLE public.escrow
      ALTER COLUMN provider_id TYPE TEXT USING provider_id::TEXT;
    RAISE NOTICE 'escrow.provider_id changed from UUID to TEXT';
  END IF;
END $$;

-- Add FK to users(id) now that the column is TEXT.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
   WHERE tc.table_schema    = 'public'
     AND tc.table_name      = 'escrow'
     AND tc.constraint_type = 'FOREIGN KEY'
     AND kcu.column_name    = 'provider_id'
  ) THEN
    ALTER TABLE public.escrow
      ADD CONSTRAINT escrow_provider_user_id_fkey
      FOREIGN KEY (provider_id) REFERENCES public.users(id) ON DELETE SET NULL;
    RAISE NOTICE 'escrow: added FK provider_id → users(id)';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Extend transactions.status CHECK
-- ---------------------------------------------------------------------------
-- PostgreSQL requires dropping and re-adding the CHECK constraint to add values.
DO $$
DECLARE
  ck_name TEXT;
BEGIN
  SELECT tc.constraint_name
    INTO ck_name
    FROM information_schema.table_constraints tc
   WHERE tc.table_schema    = 'public'
     AND tc.table_name      = 'transactions'
     AND tc.constraint_type = 'CHECK'
     AND tc.constraint_name ILIKE '%status%'
   LIMIT 1;

  IF ck_name IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.transactions DROP CONSTRAINT ' || quote_ident(ck_name);
    RAISE NOTICE 'transactions: dropped CHECK constraint %', ck_name;
  END IF;
END $$;

ALTER TABLE public.transactions
  ADD CONSTRAINT transactions_status_check
  CHECK (status IN ('pending','paid','failed','payout_pending','released','disputed','refunded'));

-- ---------------------------------------------------------------------------
-- 3. Extend escrow.status CHECK
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  ck_name TEXT;
BEGIN
  SELECT tc.constraint_name
    INTO ck_name
    FROM information_schema.table_constraints tc
   WHERE tc.table_schema    = 'public'
     AND tc.table_name      = 'escrow'
     AND tc.constraint_type = 'CHECK'
     AND tc.constraint_name ILIKE '%status%'
   LIMIT 1;

  IF ck_name IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.escrow DROP CONSTRAINT ' || quote_ident(ck_name);
    RAISE NOTICE 'escrow: dropped CHECK constraint %', ck_name;
  END IF;
END $$;

ALTER TABLE public.escrow
  ADD CONSTRAINT escrow_status_check
  CHECK (status IN ('locked','payout_pending','released','disputed','refunded'));

-- ---------------------------------------------------------------------------
-- 4. Add posts.status column
-- ---------------------------------------------------------------------------
ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','assigned','completed','disputed','cancelled'));

-- Backfill: posts with a selected provider are 'assigned'.
UPDATE public.posts
   SET status = 'assigned'
 WHERE selected_provider_id IS NOT NULL
   AND status = 'open';

CREATE INDEX IF NOT EXISTS idx_posts_status ON public.posts (status);

-- ---------------------------------------------------------------------------
-- 5. Self-application hard block
-- ---------------------------------------------------------------------------
-- Prevent applicant_user_id from equalling the post's author_user_id.
-- We use a constraint trigger because a plain CHECK can't reference another table.
-- The trigger fires BEFORE INSERT on applications.

CREATE OR REPLACE FUNCTION public.fn_block_self_application()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_author TEXT;
BEGIN
  SELECT author_user_id INTO v_author
    FROM public.posts WHERE id = NEW.post_id;

  IF v_author IS NOT NULL AND NEW.applicant_user_id = v_author THEN
    RAISE EXCEPTION 'You cannot apply to your own post.'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_block_self_application ON public.applications;
CREATE TRIGGER trg_block_self_application
  BEFORE INSERT ON public.applications
  FOR EACH ROW EXECUTE FUNCTION public.fn_block_self_application();

-- ---------------------------------------------------------------------------
-- Done
-- ---------------------------------------------------------------------------
