-- =============================================================================
-- Migration 050: Realtime for the Admin Disputes dashboard
-- =============================================================================
-- The admin dashboard subscribes (Supabase Realtime / postgres_changes) to live
-- case updates. Tables only emit changes once added to the supabase_realtime
-- publication (see migration 040). Add the arbitration tables here.
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
    WHERE pubname='supabase_realtime' AND tablename='disputes') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.disputes;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
    WHERE pubname='supabase_realtime' AND tablename='dispute_messages') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.dispute_messages;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
    WHERE pubname='supabase_realtime' AND tablename='dispute_evidence') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.dispute_evidence;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
    WHERE pubname='supabase_realtime' AND tablename='dispute_decisions') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.dispute_decisions;
  END IF;
END $$;
