-- =============================================================================
-- Migration 056: post archival (soft delete)
-- =============================================================================
-- Replaces destructive post deletion with a soft-delete / archive model.
--
-- Hard DELETE FROM posts is unsafe in this marketplace: it SET-NULLs chats.post_id
-- (colliding with idx_chats_unique_null) and is blocked by ON DELETE RESTRICT on
-- transactions/escrow. Archiving instead preserves the full audit trail
-- (reviews, reputation, escrow, transactions, disputes, job_completions,
-- notifications, chats).
--
-- archived_at is ORTHOGONAL to posts.status: the lifecycle status (open/assigned/
-- completed/disputed/cancelled) is preserved so reputation/lifecycle derivation
-- still works. Feeds filter `archived_at IS NULL`; lifecycle/admin read regardless.
-- Additive only.
-- =============================================================================

ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS archived_by TEXT; -- users.id of the archiver

COMMENT ON COLUMN public.posts.archived_at IS
  'Soft-delete timestamp. NULL = active/visible. Non-null = hidden from feeds, kept for history.';
COMMENT ON COLUMN public.posts.archived_by IS
  'users.id of who archived the post (normally the author).';

-- Feed performance: most reads want only active posts.
CREATE INDEX IF NOT EXISTS idx_posts_active
  ON public.posts (created_at DESC)
  WHERE archived_at IS NULL;
