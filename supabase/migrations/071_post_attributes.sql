-- =============================================================================
-- Migration 071 — Smart Posting SP-1: per-post dynamic attributes
-- =============================================================================
-- Adds the JSONB answers column for category-specific questions. Legacy posts
-- and old app versions keep working: the column has a DEFAULT, and the app only
-- sends `attributes` when it actually collected answers.
--
-- SAFE + ADDITIVE: two nullable-ish columns + one CHECK. No data rewrites.
-- Rollback:
--   ALTER TABLE public.posts DROP COLUMN attributes,
--     DROP COLUMN attributes_schema_version;
-- =============================================================================

ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS attributes JSONB NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS attributes_schema_version INT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'posts_attributes_is_object'
      AND conrelid = 'public.posts'::regclass
  ) THEN
    ALTER TABLE public.posts
      ADD CONSTRAINT posts_attributes_is_object
      CHECK (jsonb_typeof(attributes) = 'object');
  END IF;
END $$;

-- GIN index deliberately deferred to SP-4 (when attribute filtering ships);
-- at current volume a sequential scan is fine and the index has write cost.
