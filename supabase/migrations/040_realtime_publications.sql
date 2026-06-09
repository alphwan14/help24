-- =============================================================================
-- Migration 040: Enable Supabase Realtime for notification and application tables
-- =============================================================================
-- Supabase Realtime (postgres_changes) ONLY fires for tables that are in the
-- supabase_realtime publication. Tables are NOT added automatically on creation.
-- Missing this step is why the Flutter realtime subscriptions are silent.
-- =============================================================================

-- Add notifications and applications tables to the realtime publication.
-- IF EXISTS guard prevents duplicate-table errors on re-run.
DO $$
BEGIN
  -- notifications
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'notifications'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
  END IF;

  -- applications
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'applications'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.applications;
  END IF;
END $$;
