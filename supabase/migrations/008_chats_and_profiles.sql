-- =============================================================================
-- RUN IN SUPABASE SQL EDITOR
-- =============================================================================
-- New messaging: chats + chat_messages (replaces Firestore chat).
-- Profile images: use Storage bucket "profiles" (create in Dashboard: Storage >
--   New bucket > name: profiles, Public, or set RLS for authenticated users).
-- =============================================================================

-- Chats: one row per conversation between two users, optionally scoped to a post/job.
-- user1, user2 are Firebase UIDs (text). Canonical order: user1 < user2.
CREATE TABLE IF NOT EXISTS public.chats (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user1 text NOT NULL,
  user2 text NOT NULL,
  post_id uuid NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_message text DEFAULT '',
  CONSTRAINT chats_pkey PRIMARY KEY (id),
  CONSTRAINT chats_user_order CHECK (user1 < user2)
);

-- One chat per (user1, user2, post_id). post_id NULL = general chat.
CREATE UNIQUE INDEX IF NOT EXISTS idx_chats_unique_null
  ON public.chats (user1, user2) WHERE post_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_chats_unique_post
  ON public.chats (user1, user2, post_id) WHERE post_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_chats_user1 ON public.chats(user1);
CREATE INDEX IF NOT EXISTS idx_chats_user2 ON public.chats(user2);
CREATE INDEX IF NOT EXISTS idx_chats_updated_at ON public.chats(updated_at DESC);

-- Messages for a chat. Supports text and location (type, latitude, longitude, live_until).
CREATE TABLE IF NOT EXISTS public.chat_messages (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  chat_id uuid NOT NULL,
  sender_id text NOT NULL,
  content text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  type text NOT NULL DEFAULT 'text',
  latitude double precision,
  longitude double precision,
  live_until timestamptz,
  CONSTRAINT chat_messages_pkey PRIMARY KEY (id),
  CONSTRAINT chat_messages_chat_fkey
    FOREIGN KEY (chat_id) REFERENCES public.chats(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_chat_messages_chat_id ON public.chat_messages(chat_id);
CREATE INDEX IF NOT EXISTS idx_chat_messages_chat_created ON public.chat_messages(chat_id, created_at DESC);

-- RLS
ALTER TABLE public.chats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "chats_select" ON public.chats;
CREATE POLICY "chats_select" ON public.chats FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS "chats_insert" ON public.chats;
CREATE POLICY "chats_insert" ON public.chats FOR INSERT TO anon, authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "chats_update" ON public.chats;
CREATE POLICY "chats_update" ON public.chats FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "chat_messages_select" ON public.chat_messages;
CREATE POLICY "chat_messages_select" ON public.chat_messages FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS "chat_messages_insert" ON public.chat_messages;
CREATE POLICY "chat_messages_insert" ON public.chat_messages FOR INSERT TO anon, authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "chat_messages_update" ON public.chat_messages;
CREATE POLICY "chat_messages_update" ON public.chat_messages FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE ON public.chats TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.chat_messages TO anon, authenticated;

-- Enable Realtime: In Dashboard > Database > Replication > add "chat_messages" to publication.

-- Optional: user prefs and presence on Supabase users (for FCM, language, TOS when migrating off Firestore)
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS notifications_enabled boolean DEFAULT true;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS language text DEFAULT 'en';
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS tos_accepted_at timestamptz;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS fcm_tokens jsonb DEFAULT '[]'::jsonb;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS bio text;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS is_online boolean DEFAULT false;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS last_seen timestamptz;

COMMENT ON TABLE public.chats IS 'One row per chat; post_id optional (null = general).';
COMMENT ON TABLE public.chat_messages IS 'Realtime messages; subscribe to INSERT/UPDATE for instant UI.';
