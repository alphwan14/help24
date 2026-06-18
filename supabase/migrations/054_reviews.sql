-- =============================================================================
-- Migration 054: reviews — client→provider job reviews (reputation foundation)
-- =============================================================================
-- One review per completed job. Reviews are created ONLY after a successful,
-- paid completion (enforced in the backend service layer in Phase 3.2D — this
-- migration just builds storage). This table is the single source of rating
-- data; provider_reputation (055) DERIVES every aggregate from it.
--
-- Backend-mediated reads (RLS = service-role only), consistent with the rest of
-- the financial/trust tables. No client-side reads of this table.
-- Additive only — no destructive changes.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.reviews (
  id                 UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  post_id            UUID        NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,

  -- users.id (Firebase UID, TEXT). client = reviewer (post author); provider = reviewee.
  client_id          TEXT        NOT NULL,
  provider_id        TEXT        NOT NULL,

  rating             SMALLINT    NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment            TEXT,

  -- visible (default) | hidden (retracted/soft-deleted) | flagged (moderation).
  status             TEXT        NOT NULL DEFAULT 'visible'
                                   CHECK (status IN ('visible','hidden','flagged')),

  -- Tags reviews written on a job that went through a dispute, so the reputation
  -- engine can down-weight potential retaliation / make-good bias.
  from_disputed_job  BOOLEAN     NOT NULL DEFAULT FALSE,

  -- One public provider response (populated in a later phase).
  provider_reply     TEXT,
  provider_reply_at  TIMESTAMPTZ,

  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  edited_at          TIMESTAMPTZ,

  -- Rule 2: one review per job — no duplicates, no review spam.
  CONSTRAINT reviews_one_per_post UNIQUE (post_id),
  -- Self-review block (a provider can never review their own job).
  CONSTRAINT reviews_no_self CHECK (client_id <> provider_id)
);

CREATE INDEX IF NOT EXISTS idx_reviews_provider ON public.reviews (provider_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reviews_client   ON public.reviews (client_id);

ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE policyname = 'reviews_service_role' AND tablename = 'reviews'
  ) THEN
    CREATE POLICY reviews_service_role ON public.reviews USING (true) WITH CHECK (true);
  END IF;
END $$;

GRANT ALL ON public.reviews TO service_role;
