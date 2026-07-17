-- =============================================================================
-- Migration 082: saved_items — personal shortlist (posts + providers)
-- =============================================================================
-- Users can save requests, offers, jobs (all rows of `posts`) and providers
-- (rows of `users`) into a private shortlist shown under Profile → Saved.
--
-- item_type 'post'     → item_id = posts.id (uuid, stored as text)
-- item_type 'provider' → item_id = users.id (firebase uid, text)
-- No FK on item_id (it spans two tables by design); reads tolerate dangling
-- ids (deleted/archived posts simply drop out of the shortlist client-side).
--
-- RLS follows the app-wide convention (see 061/080/081): owner scoping via
-- auth.jwt() ->> 'user_id' — never auth.uid() (Firebase sub is not a UUID).
-- Saving requires sign-in, so only `authenticated` is granted; there is no
-- anon path.
--
-- SAFE + ADDITIVE. Rollback: DROP TABLE public.saved_items;
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.saved_items (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    TEXT        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  item_type  TEXT        NOT NULL CHECK (item_type IN ('post', 'provider')),
  item_id    TEXT        NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, item_type, item_id)
);

CREATE INDEX IF NOT EXISTS idx_saved_items_user_created
  ON public.saved_items (user_id, created_at DESC);

ALTER TABLE public.saved_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS saved_items_owner ON public.saved_items;
CREATE POLICY saved_items_owner ON public.saved_items
  FOR ALL TO authenticated
  USING      (user_id = (auth.jwt() ->> 'user_id'))
  WITH CHECK (user_id = (auth.jwt() ->> 'user_id'));

DROP POLICY IF EXISTS saved_items_service_role ON public.saved_items;
CREATE POLICY saved_items_service_role ON public.saved_items
  TO service_role
  USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, DELETE ON public.saved_items TO authenticated;
GRANT ALL ON public.saved_items TO service_role;
