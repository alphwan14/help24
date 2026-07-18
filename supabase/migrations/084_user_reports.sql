-- =============================================================================
-- Migration 084: user_reports — in-app "Report user" from conversations
-- =============================================================================
-- The chat three-dot menu and the message long-press menu let a signed-in
-- user report the other participant (spam / scam / harassment / other).
-- Reports land here for admin review (service role / admin dashboard).
--
-- RLS follows the app-wide convention (061/080/081/082): owner scoping via
-- auth.jwt() ->> 'user_id' — never auth.uid() (Firebase sub is not a UUID).
-- Reporters may only INSERT their own reports; there is no user-facing read
-- path (SELECT is service-role only) so reports stay confidential.
--
-- The app degrades gracefully until this is applied: submission fails softly
-- with a "could not submit" message.
--
-- SAFE + ADDITIVE. Rollback: DROP TABLE public.user_reports;
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.user_reports (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id      TEXT        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  reported_user_id TEXT        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  chat_id          UUID        NULL,
  post_id          UUID        NULL,
  message_id       UUID        NULL,
  reason           TEXT        NOT NULL CHECK (reason IN
                    ('spam', 'scam_or_fraud', 'inappropriate_content', 'harassment', 'other')),
  details          TEXT        NOT NULL DEFAULT '',
  status           TEXT        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'reviewed', 'dismissed')),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT user_reports_not_self CHECK (reporter_id <> reported_user_id)
);

CREATE INDEX IF NOT EXISTS idx_user_reports_status_created
  ON public.user_reports (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_user_reports_reported_user
  ON public.user_reports (reported_user_id, created_at DESC);

ALTER TABLE public.user_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_reports_insert_own ON public.user_reports;
CREATE POLICY user_reports_insert_own ON public.user_reports
  FOR INSERT TO authenticated
  WITH CHECK (reporter_id = (auth.jwt() ->> 'user_id'));

DROP POLICY IF EXISTS user_reports_service_role ON public.user_reports;
CREATE POLICY user_reports_service_role ON public.user_reports
  TO service_role
  USING (true) WITH CHECK (true);

GRANT INSERT ON public.user_reports TO authenticated;
GRANT ALL ON public.user_reports TO service_role;
