-- =============================================================================
-- RUN THIS IN SUPABASE SQL EDITOR
-- =============================================================================
-- Real-time messaging: conversations + messages
-- Conversations created only when request/application is accepted.
-- Enable Realtime on messages for instant updates.
-- =============================================================================

-- Conversations: one row per chat between two users
CREATE TABLE IF NOT EXISTS public.conversations (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user1_id text NOT NULL,
  user2_id text NOT NULL,
  last_message text DEFAULT ''::text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT conversations_pkey PRIMARY KEY (id),
  CONSTRAINT conversations_users_ordering CHECK (user1_id < user2_id)
);

-- Messages: one row per message in a conversation
CREATE TABLE IF NOT EXISTS public.messages (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL,
  sender_id text NOT NULL,
  message text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT messages_pkey PRIMARY KEY (id),
  CONSTRAINT messages_conversation_fkey
    FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_conversations_user1_id ON public.conversations(user1_id);
CREATE INDEX IF NOT EXISTS idx_conversations_user2_id ON public.conversations(user2_id);
CREATE INDEX IF NOT EXISTS idx_conversations_updated_at ON public.conversations(updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_messages_conversation_id ON public.messages(conversation_id);
CREATE INDEX IF NOT EXISTS idx_messages_conversation_created ON public.messages(conversation_id, created_at DESC);

-- Unique constraint: one conversation per pair (user1_id, user2_id) with canonical ordering
CREATE UNIQUE INDEX IF NOT EXISTS idx_conversations_user_pair
  ON public.conversations(user1_id, user2_id);

-- Required: grant table access to anon and authenticated (fixes "permission denied" 42501)
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.conversations TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.messages TO anon, authenticated;

-- Enable Realtime for messages: In Supabase Dashboard go to
-- Database > Replication > add table "messages" to supabase_realtime.

-- RLS
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Conversations select by participants" ON public.conversations;
CREATE POLICY "Conversations select by participants"
  ON public.conversations FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "Conversations insert" ON public.conversations;
CREATE POLICY "Conversations insert"
  ON public.conversations FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

DROP POLICY IF EXISTS "Conversations update" ON public.conversations;
CREATE POLICY "Conversations update"
  ON public.conversations FOR UPDATE
  TO anon, authenticated
  USING (true)
  WITH CHECK (true);

DROP POLICY IF EXISTS "Messages select" ON public.messages;
CREATE POLICY "Messages select"
  ON public.messages FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS "Messages insert" ON public.messages;
CREATE POLICY "Messages insert"
  ON public.messages FOR INSERT
  TO anon, authenticated
  WITH CHECK (true);

COMMENT ON TABLE public.conversations IS 'One row per chat; created when request/application is accepted.';
COMMENT ON TABLE public.messages IS 'Realtime messages; subscribe to INSERT for instant UI.';
