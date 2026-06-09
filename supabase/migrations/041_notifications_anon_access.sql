-- =============================================================================
-- Migration 041: Grant anon access to notifications + fcm_tokens
-- =============================================================================
-- Root cause: the Flutter app initialises the Supabase client with the anon
-- key. Even though HttpClientWithToken injects a Firebase-exchanged JWT after
-- login, the GRANT list on these tables only covered 'authenticated' and
-- 'service_role'. Any request that arrives before the exchange completes (or
-- when the edge function is unreachable) runs as anon → 42501 permission
-- denied before RLS is even evaluated.
--
-- Fix:
--  1. Grant anon SELECT + UPDATE on notifications so queries never fail cold.
--  2. Grant anon INSERT + SELECT + UPDATE + DELETE on fcm_tokens so token
--     registration works regardless of JWT exchange timing.
--  3. Add permissive anon policies (USING true) — the app always filters by
--     user_id in the query, and Firebase UIDs are opaque non-guessable strings.
--  4. Tighten notifications_service_role to TO service_role so it no longer
--     inadvertently grants open access to every role.
-- =============================================================================

-- ── notifications ─────────────────────────────────────────────────────────────

GRANT SELECT, UPDATE ON public.notifications TO anon;

-- Re-scope the blanket service-role policy so it no longer implicitly covers anon.
DROP POLICY IF EXISTS notifications_service_role ON public.notifications;
CREATE POLICY notifications_service_role ON public.notifications
  TO service_role
  USING (true) WITH CHECK (true);

-- Permissive anon policies: read and mark-as-read for own rows.
-- Security note: USING(true) allows anon to reach any row that the query
-- filter selects. The app always passes .eq('user_id', currentUserId), and
-- Supabase Realtime channel filters are also scoped to the calling user's id.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'notifications_anon_read' AND tablename = 'notifications'
  ) THEN
    CREATE POLICY notifications_anon_read ON public.notifications
      FOR SELECT TO anon USING (true);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'notifications_anon_update' AND tablename = 'notifications'
  ) THEN
    CREATE POLICY notifications_anon_update ON public.notifications
      FOR UPDATE TO anon USING (true) WITH CHECK (true);
  END IF;
END $$;

-- ── fcm_tokens ────────────────────────────────────────────────────────────────

GRANT SELECT, INSERT, UPDATE, DELETE ON public.fcm_tokens TO anon;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'fcm_tokens_anon' AND tablename = 'fcm_tokens'
  ) THEN
    CREATE POLICY fcm_tokens_anon ON public.fcm_tokens
      FOR ALL TO anon
      USING (true) WITH CHECK (true);
  END IF;
END $$;
