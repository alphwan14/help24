-- =============================================================================
-- OPTIMIZED HYBRID RLS: Secure but works with anon key + Firebase
-- This is the best of both worlds - maintains security while allowing the app to function
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. CREATE A HELPER FUNCTION THAT WORKS WITH ANON KEY
-- -----------------------------------------------------------------------------
-- This function safely extracts user_id from JWT even with anon key
CREATE OR REPLACE FUNCTION public.get_user_id_from_request()
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  user_id TEXT;
BEGIN
  -- Try to get from auth.uid() (Supabase)
  BEGIN
    user_id := auth.uid()::text;
    IF user_id IS NOT NULL AND user_id != '' THEN
      RETURN user_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- Ignore errors, continue to next method
  END;
  
  -- Try to get from JWT claims (Firebase)
  BEGIN
    user_id := current_setting('request.jwt.claims', true)::json->>'user_id';
    IF user_id IS NOT NULL AND user_id != '' THEN
      RETURN user_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- Ignore errors
  END;
  
  -- Return null if no user found (for anon key with no user context)
  RETURN NULL;
END;
$$;

-- Grant execute to anon and authenticated
GRANT EXECUTE ON FUNCTION public.get_user_id_from_request() TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. SMART RLS POLICIES - Work with anon key but maintain security
-- -----------------------------------------------------------------------------

-- Enable RLS
ALTER TABLE public.chats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

-- ----- CHATS POLICIES (Smart) -----

-- SELECT: Users see chats they're part of; anon with no user_id sees nothing
DROP POLICY IF EXISTS "chats_select_smart" ON public.chats;
CREATE POLICY "chats_select_smart" ON public.chats
  FOR SELECT TO anon, authenticated
  USING (
    public.get_user_id_from_request() IS NOT NULL
    AND (
      user1 = public.get_user_id_from_request() 
      OR user2 = public.get_user_id_from_request()
    )
  );

-- INSERT: Users can create chats where they're a participant
DROP POLICY IF EXISTS "chats_insert_smart" ON public.chats;
CREATE POLICY "chats_insert_smart" ON public.chats
  FOR INSERT TO anon, authenticated
  WITH CHECK (
    public.get_user_id_from_request() IS NOT NULL
    AND (
      user1 = public.get_user_id_from_request() 
      OR user2 = public.get_user_id_from_request()
    )
    AND user1 != user2 -- Prevent self-chats
  );

-- UPDATE: Users can update their own chats
DROP POLICY IF EXISTS "chats_update_smart" ON public.chats;
CREATE POLICY "chats_update_smart" ON public.chats
  FOR UPDATE TO anon, authenticated
  USING (
    public.get_user_id_from_request() IS NOT NULL
    AND (
      user1 = public.get_user_id_from_request() 
      OR user2 = public.get_user_id_from_request()
    )
  )
  WITH CHECK (
    public.get_user_id_from_request() IS NOT NULL
    AND (
      user1 = public.get_user_id_from_request() 
      OR user2 = public.get_user_id_from_request()
    )
  );

-- ----- CHAT MESSAGES POLICIES (Smart) -----

-- SELECT: Only see messages from chats you're in
DROP POLICY IF EXISTS "chat_messages_select_smart" ON public.chat_messages;
CREATE POLICY "chat_messages_select_smart" ON public.chat_messages
  FOR SELECT TO anon, authenticated
  USING (
    public.get_user_id_from_request() IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM public.chats c
      WHERE c.id = chat_messages.chat_id
        AND (
          c.user1 = public.get_user_id_from_request() 
          OR c.user2 = public.get_user_id_from_request()
        )
    )
  );

-- INSERT: Can only insert messages as yourself in your chats
DROP POLICY IF EXISTS "chat_messages_insert_smart" ON public.chat_messages;
CREATE POLICY "chat_messages_insert_smart" ON public.chat_messages
  FOR INSERT TO anon, authenticated
  WITH CHECK (
    public.get_user_id_from_request() IS NOT NULL
    AND sender_id = public.get_user_id_from_request()
    AND EXISTS (
      SELECT 1 FROM public.chats c
      WHERE c.id = chat_messages.chat_id
        AND (
          c.user1 = public.get_user_id_from_request() 
          OR c.user2 = public.get_user_id_from_request()
        )
    )
  );

-- UPDATE: Can only update your own messages
DROP POLICY IF EXISTS "chat_messages_update_smart" ON public.chat_messages;
CREATE POLICY "chat_messages_update_smart" ON public.chat_messages
  FOR UPDATE TO anon, authenticated
  USING (
    public.get_user_id_from_request() IS NOT NULL
    AND sender_id = public.get_user_id_from_request()
    AND EXISTS (
      SELECT 1 FROM public.chats c
      WHERE c.id = chat_messages.chat_id
        AND (
          c.user1 = public.get_user_id_from_request() 
          OR c.user2 = public.get_user_id_from_request()
        )
    )
  )
  WITH CHECK (
    public.get_user_id_from_request() IS NOT NULL
    AND sender_id = public.get_user_id_from_request()
  );

-- Grant necessary permissions to anon
GRANT SELECT, INSERT, UPDATE ON public.chats TO anon;
GRANT SELECT, INSERT, UPDATE ON public.chat_messages TO anon;

-- -----------------------------------------------------------------------------
-- 3. NOTIFICATION SYSTEM (Works with service role)
-- -----------------------------------------------------------------------------

-- Create notification queue (if not exists)
CREATE TABLE IF NOT EXISTS public.notification_queue (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  chat_id uuid NOT NULL,
  sender_id text NOT NULL,
  recipient_id text NOT NULL,
  content text,
  processed boolean DEFAULT false,
  created_at timestamptz DEFAULT now(),
  processed_at timestamptz
);

-- Index for performance
CREATE INDEX IF NOT EXISTS idx_notification_queue_unprocessed 
  ON public.notification_queue(processed) 
  WHERE processed = false;

-- Function to queue notifications
CREATE OR REPLACE FUNCTION public.queue_notification_on_message()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_recipient_id text;
BEGIN
  -- Get the other participant
  SELECT 
    CASE 
      WHEN c.user1 = NEW.sender_id THEN c.user2
      ELSE c.user1
    END INTO v_recipient_id
  FROM public.chats c
  WHERE c.id = NEW.chat_id;
  
  -- Queue notification
  INSERT INTO public.notification_queue (
    message_id, chat_id, sender_id, recipient_id, content
  ) VALUES (
    NEW.id, NEW.chat_id, NEW.sender_id, v_recipient_id, NEW.content
  );
  
  RETURN NEW;
END;
$$;

-- Create trigger
DROP TRIGGER IF EXISTS message_notification_trigger ON public.chat_messages;
CREATE TRIGGER message_notification_trigger
  AFTER INSERT ON public.chat_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.queue_notification_on_message();

-- -----------------------------------------------------------------------------
-- 4. DEBUGGING VIEW (Temporary - remove in production)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.debug_auth_status AS
SELECT 
  public.get_user_id_from_request() as current_user_id,
  auth.role() as auth_role,
  current_setting('request.jwt.claims', true) as jwt_claims;

GRANT SELECT ON public.debug_auth_status TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- 5. COMMENTS
-- -----------------------------------------------------------------------------
COMMENT ON FUNCTION public.get_user_id_from_request() IS 'Safely extracts user_id from any auth method. Returns NULL for anon key with no user.';
COMMENT ON POLICY "chats_select_smart" ON public.chats IS 'Secure: Only shows chats where user is participant. Works with both Supabase and Firebase auth.';
COMMENT ON POLICY "chat_messages_insert_smart" ON public.chat_messages IS 'Secure: Only allows users to send messages as themselves in their chats.';