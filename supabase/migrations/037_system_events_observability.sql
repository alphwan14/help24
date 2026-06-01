-- =============================================================================
-- Migration 037: system_events observability columns
-- =============================================================================
-- Adds retry tracking and dead-letter support to system_events.
--
-- retry_count  — incremented on every failed processing attempt
-- last_error   — the error message from the most recent failure
-- dead_letter  — permanently failed; excluded from the retry loop
--
-- EventProcessorService enforces MAX_RETRIES=3. After 3 failures the event
-- is marked dead_letter=true and logged as [PROCESSOR][DEAD_LETTER].
-- Dead-letter events can be replayed manually via POST /admin/events/replay.
-- =============================================================================

ALTER TABLE public.system_events
  ADD COLUMN IF NOT EXISTS retry_count  INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_error   TEXT,
  ADD COLUMN IF NOT EXISTS dead_letter  BOOLEAN NOT NULL DEFAULT FALSE;

-- Replace the existing retry index to also filter out dead-letter events.
DROP INDEX IF EXISTS idx_system_events_retry;

CREATE INDEX IF NOT EXISTS idx_system_events_retry
  ON public.system_events (processed, dead_letter, retry_count, created_at)
  WHERE processed = FALSE AND dead_letter = FALSE;

-- Separate index for dead-letter queue queries (admin visibility).
CREATE INDEX IF NOT EXISTS idx_system_events_dead_letter
  ON public.system_events (dead_letter, created_at DESC)
  WHERE dead_letter = TRUE;
