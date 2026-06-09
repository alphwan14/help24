-- =============================================================================
-- Migration 039: Dedicated FCM tokens table
-- =============================================================================
-- Replaces the users.fcm_tokens JSONB array.
-- Benefits: per-device platform tracking, proper deduplication, cascading
-- delete on logout/user removal, indexed lookups.
--
-- The UNIQUE constraint is on (token) alone because an FCM token belongs to
-- exactly one device. If the same physical device re-registers under a
-- different user (e.g. logout + new login), the upsert re-assigns the token.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.fcm_tokens (
  id         UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    TEXT        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  token      TEXT        NOT NULL,
  platform   TEXT        NOT NULL DEFAULT 'android',  -- android | ios | web
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT fcm_tokens_token_unique UNIQUE (token)
);

CREATE INDEX IF NOT EXISTS idx_fcm_tokens_user_id ON public.fcm_tokens (user_id);

ALTER TABLE public.fcm_tokens ENABLE ROW LEVEL SECURITY;

-- Service role writes tokens; users can only read/delete their own.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'fcm_tokens_owner' AND tablename = 'fcm_tokens'
  ) THEN
    CREATE POLICY fcm_tokens_owner ON public.fcm_tokens
      FOR ALL
      USING (user_id = auth.uid()::TEXT)
      WITH CHECK (user_id = auth.uid()::TEXT);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'fcm_tokens_service_role' AND tablename = 'fcm_tokens'
  ) THEN
    CREATE POLICY fcm_tokens_service_role ON public.fcm_tokens
      TO service_role
      USING (true) WITH CHECK (true);
  END IF;
END $$;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.fcm_tokens TO authenticated;
GRANT ALL ON public.fcm_tokens TO service_role;
