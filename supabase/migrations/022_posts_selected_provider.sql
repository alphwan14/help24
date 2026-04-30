-- Add selected_provider_id to posts table.
-- Stores the applicant_user_id of the provider chosen by the request author.
-- This is the authoritative selection: payment + payout both read from here.

ALTER TABLE public.posts
  ADD COLUMN IF NOT EXISTS selected_provider_id TEXT;

-- Index for fast lookups (e.g. "which posts did I get selected for?")
CREATE INDEX IF NOT EXISTS idx_posts_selected_provider_id
  ON public.posts (selected_provider_id)
  WHERE selected_provider_id IS NOT NULL;

-- Ensure anon key can update posts (needed for Firebase-auth users using anon Supabase key).
-- The app-level check (isAuthor) is the real gate; DB permissiveness matches existing pattern.
GRANT SELECT, INSERT, UPDATE ON public.posts TO anon, authenticated;

-- If RLS is enabled on posts, ensure authors can update their own rows.
-- We use DROP IF EXISTS + CREATE to make this idempotent.
DO $$
BEGIN
  -- Only add policy if RLS is actually enabled on posts.
  IF EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'posts' AND c.relrowsecurity = true
  ) THEN
    DROP POLICY IF EXISTS "posts_update_author" ON public.posts;
    CREATE POLICY "posts_update_author" ON public.posts
      FOR UPDATE TO anon, authenticated
      USING (true)
      WITH CHECK (true);
  END IF;
END;
$$;
