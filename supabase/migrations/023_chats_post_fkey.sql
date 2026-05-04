-- =============================================================================
-- Migration 023: Add FK from chats.post_id → posts.id
-- =============================================================================
-- WHY: PostgREST (Supabase) discovers join relationships exclusively through
-- foreign key constraints. chats.post_id (uuid) existed since migration 008
-- but was never linked to posts(id), so .select('*, posts(title)') threw
-- "Could not find a relationship between 'chats' and 'posts'".
--
-- SAFE: ON DELETE SET NULL keeps chat history if a post is deleted.
-- =============================================================================

-- Step 1: Null-out any orphaned post_id values that no longer exist in posts.
-- This prevents the FK creation from failing on stale references.
UPDATE public.chats
SET post_id = NULL
WHERE post_id IS NOT NULL
  AND post_id NOT IN (SELECT id FROM public.posts);

-- Step 2: Add the foreign key constraint.
-- Idempotent: won't fail if run twice (drops first).
ALTER TABLE public.chats
  DROP CONSTRAINT IF EXISTS chats_post_id_fkey;

ALTER TABLE public.chats
  ADD CONSTRAINT chats_post_id_fkey
  FOREIGN KEY (post_id)
  REFERENCES public.posts(id)
  ON DELETE SET NULL;   -- keep chat history; just clear the post reference

-- Step 3: Index the FK column for fast join performance.
CREATE INDEX IF NOT EXISTS idx_chats_post_id ON public.chats(post_id);

-- Verify
-- SELECT COUNT(*) FROM public.chats WHERE post_id IS NOT NULL;
-- SELECT c.id, c.post_id, p.title
--   FROM public.chats c
--   LEFT JOIN public.posts p ON c.post_id = p.id
--   LIMIT 10;
