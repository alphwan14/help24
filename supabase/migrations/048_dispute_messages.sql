-- =============================================================================
-- Migration 048: dispute_messages — the "court thread" / case discussion
-- =============================================================================
-- A threaded conversation scoped to one dispute. Admins and both parties can
-- post; the system posts automated entries (e.g. "Case assigned to …",
-- "Decision issued: FULL_RELEASE"). This is the human-readable case timeline.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.dispute_messages (
  id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  dispute_id  UUID        NOT NULL REFERENCES public.disputes(id) ON DELETE CASCADE,

  sender_type TEXT        NOT NULL CHECK (sender_type IN ('client','provider','admin','system')),
  -- users.id (TEXT) for client/provider, admin_users.id (UUID as text) for admin,
  -- NULL for system messages.
  sender_id   TEXT,
  message     TEXT        NOT NULL CHECK (length(btrim(message)) > 0),

  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_dispute_messages_dispute ON public.dispute_messages (dispute_id, created_at);

ALTER TABLE public.dispute_messages ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'dispute_messages_service_role' AND tablename = 'dispute_messages'
  ) THEN
    CREATE POLICY dispute_messages_service_role ON public.dispute_messages
      USING (true) WITH CHECK (true);
  END IF;
END $$;

GRANT ALL ON public.dispute_messages TO service_role;
