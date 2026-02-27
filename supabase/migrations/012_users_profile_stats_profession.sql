-- =============================================================================
-- Users: profession, rating stats, completed_jobs_count for profile screen.
-- =============================================================================

ALTER TABLE public.users ADD COLUMN IF NOT EXISTS profession text DEFAULT '';
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS average_rating double precision DEFAULT 0;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS total_reviews integer DEFAULT 0;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS completed_jobs_count integer DEFAULT 0;

COMMENT ON COLUMN public.users.profession IS 'User profession for profile display.';
COMMENT ON COLUMN public.users.average_rating IS 'Cached average rating from reviews.';
COMMENT ON COLUMN public.users.total_reviews IS 'Total number of reviews received.';
COMMENT ON COLUMN public.users.completed_jobs_count IS 'Incremented when user marks a job as completed.';
