-- =============================================================================
-- Production indexes for posts and applications (safe to run multiple times).
-- =============================================================================

-- Supports ORDER BY created_at DESC and range queries on posts/jobs.
CREATE INDEX IF NOT EXISTS idx_posts_created_at ON public.posts(created_at DESC);

-- Supports filtering applications by post_id (e.g. getApplicationsForPost, hasApplied).
CREATE INDEX IF NOT EXISTS idx_applications_post_id ON public.applications(post_id);
