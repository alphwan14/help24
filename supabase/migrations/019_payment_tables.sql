-- =============================================================================
-- 019: Payment tables — providers, phone_verifications, transactions, escrow
--
-- Safe to run multiple times (IF NOT EXISTS / DO $$ guards throughout).
-- Fixes: transactions.job_id → post_id (NOT NULL constraint was causing
--        "null value in column job_id" errors from the NestJS backend).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- providers
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.providers (
  id             UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  name           TEXT        NOT NULL,
  phone_login    TEXT        NOT NULL UNIQUE,
  phone_payout   TEXT        NOT NULL,
  services       TEXT[]      NOT NULL DEFAULT '{}',
  location       TEXT        NOT NULL,
  payout_verified BOOLEAN    NOT NULL DEFAULT FALSE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.providers ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'providers_service_role'
                 AND tablename = 'providers') THEN
    CREATE POLICY providers_service_role ON public.providers USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- phone_verifications
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.phone_verifications (
  id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider_id UUID        NOT NULL REFERENCES public.providers(id) ON DELETE CASCADE,
  phone       TEXT        NOT NULL,
  otp_code    TEXT        NOT NULL,
  type        TEXT        NOT NULL DEFAULT 'payout'
                          CHECK (type IN ('payout')),
  status      TEXT        NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending', 'verified', 'expired')),
  expires_at  TIMESTAMPTZ NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_phone_verifications_provider_status
  ON public.phone_verifications (provider_id, status, expires_at DESC);

ALTER TABLE public.phone_verifications ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'phone_verifications_service_role'
                 AND tablename = 'phone_verifications') THEN
    CREATE POLICY phone_verifications_service_role ON public.phone_verifications
      USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- transactions
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.transactions (
  id                   UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  post_id              UUID        NOT NULL REFERENCES public.posts(id) ON DELETE RESTRICT,
  buyer_user_id        TEXT        NOT NULL,
  amount               INTEGER     NOT NULL CHECK (amount > 0),
  fee                  INTEGER     NOT NULL CHECK (fee >= 0),
  total_paid           INTEGER     NOT NULL CHECK (total_paid > 0),
  status               TEXT        NOT NULL DEFAULT 'pending'
                                   CHECK (status IN ('pending','paid','failed','payout_pending','released')),
  checkout_request_id  TEXT,
  conversation_id      TEXT,
  mpesa_receipt        TEXT,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Fix: rename job_id → post_id, or drop job_id if post_id already exists.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'transactions' AND column_name = 'job_id'
  ) THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'transactions' AND column_name = 'post_id'
    ) THEN
      ALTER TABLE public.transactions DROP COLUMN job_id;
      RAISE NOTICE 'transactions.job_id dropped (post_id already existed)';
    ELSE
      ALTER TABLE public.transactions RENAME COLUMN job_id TO post_id;
      RAISE NOTICE 'transactions.job_id renamed to post_id';
    END IF;
  END IF;
END $$;

-- Add any columns the pre-existing table may be missing.
ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS post_id             UUID    REFERENCES public.posts(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS buyer_user_id       TEXT,
  ADD COLUMN IF NOT EXISTS amount              INTEGER,
  ADD COLUMN IF NOT EXISTS fee                 INTEGER,
  ADD COLUMN IF NOT EXISTS total_paid          INTEGER,
  ADD COLUMN IF NOT EXISTS status              TEXT    NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS checkout_request_id TEXT,
  ADD COLUMN IF NOT EXISTS conversation_id     TEXT,
  ADD COLUMN IF NOT EXISTS mpesa_receipt       TEXT,
  ADD COLUMN IF NOT EXISTS created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- Ensure post_id is NOT NULL (in case it was added as nullable).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'transactions'
      AND column_name  = 'post_id'
      AND is_nullable  = 'YES'
  ) THEN
    ALTER TABLE public.transactions ALTER COLUMN post_id SET NOT NULL;
    RAISE NOTICE 'transactions.post_id set NOT NULL';
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_transactions_post_id
  ON public.transactions (post_id);
CREATE INDEX IF NOT EXISTS idx_transactions_checkout_request_id
  ON public.transactions (checkout_request_id);
CREATE INDEX IF NOT EXISTS idx_transactions_conversation_id
  ON public.transactions (conversation_id);
CREATE INDEX IF NOT EXISTS idx_transactions_status
  ON public.transactions (status);
CREATE INDEX IF NOT EXISTS idx_transactions_created_at
  ON public.transactions (created_at DESC);

ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'transactions_service_role'
                 AND tablename = 'transactions') THEN
    CREATE POLICY transactions_service_role ON public.transactions
      USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- escrow
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.escrow (
  id             UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  post_id        UUID        NOT NULL REFERENCES public.posts(id) ON DELETE RESTRICT,
  transaction_id UUID        NOT NULL REFERENCES public.transactions(id) ON DELETE RESTRICT,
  amount         INTEGER     NOT NULL CHECK (amount > 0),
  status         TEXT        NOT NULL DEFAULT 'locked'
                             CHECK (status IN ('locked','payout_pending','released')),
  provider_id    UUID        REFERENCES public.providers(id),
  released_at    TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Fix: rename job_id → post_id on escrow, or drop job_id if post_id already exists.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'escrow' AND column_name = 'job_id'
  ) THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'escrow' AND column_name = 'post_id'
    ) THEN
      ALTER TABLE public.escrow DROP COLUMN job_id;
      RAISE NOTICE 'escrow.job_id dropped (post_id already existed)';
    ELSE
      ALTER TABLE public.escrow RENAME COLUMN job_id TO post_id;
      RAISE NOTICE 'escrow.job_id renamed to post_id';
    END IF;
  END IF;
END $$;

-- Add any columns the pre-existing escrow table may be missing.
ALTER TABLE public.escrow
  ADD COLUMN IF NOT EXISTS post_id        UUID        REFERENCES public.posts(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS transaction_id UUID        REFERENCES public.transactions(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS amount         INTEGER,
  ADD COLUMN IF NOT EXISTS status         TEXT        NOT NULL DEFAULT 'locked',
  ADD COLUMN IF NOT EXISTS provider_id    UUID        REFERENCES public.providers(id),
  ADD COLUMN IF NOT EXISTS released_at    TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_escrow_post_id
  ON public.escrow (post_id);
CREATE INDEX IF NOT EXISTS idx_escrow_transaction_id
  ON public.escrow (transaction_id);
CREATE INDEX IF NOT EXISTS idx_escrow_status
  ON public.escrow (status);

ALTER TABLE public.escrow ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'escrow_service_role'
                 AND tablename = 'escrow') THEN
    CREATE POLICY escrow_service_role ON public.escrow USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Grants (service_role bypasses RLS, but anon/authenticated need explicit grants
-- if ever exposed via PostgREST directly — backend uses service_role only).
-- ---------------------------------------------------------------------------
GRANT ALL ON public.providers          TO service_role;
GRANT ALL ON public.phone_verifications TO service_role;
GRANT ALL ON public.transactions        TO service_role;
GRANT ALL ON public.escrow              TO service_role;
