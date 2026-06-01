-- =============================================================================
-- Migration 033: in-app notifications table
-- =============================================================================
-- Stores persistent in-app notifications for each user.
-- FCM push notifications are fire-and-forget; this table enables an in-app
-- inbox with unread counts that survive app restarts.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.notifications (
  id         UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    TEXT        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

  -- Notification type — mirrors the FCM data.type field for client routing.
  type       TEXT        NOT NULL,

  title      TEXT        NOT NULL,
  body       TEXT        NOT NULL,

  -- Arbitrary JSON metadata (post_id, transaction_id, dispute_id, etc.)
  data       JSONB       NOT NULL DEFAULT '{}',

  read       BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Primary query: unread notifications for a user, newest first.
CREATE INDEX IF NOT EXISTS idx_notifications_user_unread
  ON public.notifications (user_id, read, created_at DESC);

-- Supports "mark all as read" and "unread count" queries.
CREATE INDEX IF NOT EXISTS idx_notifications_user_id
  ON public.notifications (user_id);

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- Users can only read their own notifications; writes go through service_role.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'notifications_owner_read'
      AND tablename  = 'notifications'
  ) THEN
    CREATE POLICY notifications_owner_read ON public.notifications
      FOR SELECT
      USING (user_id = auth.uid()::TEXT);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'notifications_owner_update'
      AND tablename  = 'notifications'
  ) THEN
    -- Allow the user to mark their own notifications as read.
    CREATE POLICY notifications_owner_update ON public.notifications
      FOR UPDATE
      USING (user_id = auth.uid()::TEXT)
      WITH CHECK (user_id = auth.uid()::TEXT);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE policyname = 'notifications_service_role'
      AND tablename  = 'notifications'
  ) THEN
    CREATE POLICY notifications_service_role ON public.notifications
      USING (true) WITH CHECK (true);
  END IF;
END $$;

GRANT SELECT, UPDATE ON public.notifications TO authenticated;
GRANT ALL ON public.notifications TO service_role;
