-- =============================================================================
-- Migration 035: system_events — unified event audit log
-- =============================================================================
-- Every significant state change emits a row here.
-- processed=false rows are retried by EventProcessorService every 60 s.
-- This table is append-only; rows are never updated except to set processed=true.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.system_events (
  id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Canonical event type string (e.g. 'payment.success', 'job.approved').
  type           TEXT        NOT NULL,

  -- The user who triggered the event (nullable for system-generated events).
  actor_user_id  TEXT        REFERENCES public.users(id) ON DELETE SET NULL,

  -- The primary domain entity this event concerns.
  entity_type    TEXT        NOT NULL
    CHECK (entity_type IN ('post','chat','payment','message','application','dispute','escrow','job_completion')),
  entity_id      TEXT        NOT NULL,

  -- Arbitrary structured payload (IDs, amounts, titles needed by handlers).
  payload        JSONB       NOT NULL DEFAULT '{}',

  -- false until EventProcessorService has handled the event successfully.
  -- Unprocessed events are retried by the background loop.
  processed      BOOLEAN     NOT NULL DEFAULT FALSE,

  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Retry loop query: recent unprocessed events ordered oldest-first.
CREATE INDEX IF NOT EXISTS idx_system_events_retry
  ON public.system_events (processed, created_at)
  WHERE processed = FALSE;

-- Audit lookups: all events for a given entity.
CREATE INDEX IF NOT EXISTS idx_system_events_entity
  ON public.system_events (entity_type, entity_id, created_at DESC);

-- Type-based queries (e.g. "all payment.success events").
CREATE INDEX IF NOT EXISTS idx_system_events_type
  ON public.system_events (type, created_at DESC);

-- RLS: only service_role writes; authenticated users cannot read the event log.
ALTER TABLE public.system_events ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'system_events_service_role'
      AND tablename  = 'system_events'
  ) THEN
    CREATE POLICY system_events_service_role ON public.system_events
      USING (true) WITH CHECK (true);
  END IF;
END $$;

GRANT ALL ON public.system_events TO service_role;
-- Authenticated users have no direct access; reads go through the backend API.
