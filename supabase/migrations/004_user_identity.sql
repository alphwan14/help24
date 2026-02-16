-- =============================================================================
-- RUN THIS IN SUPABASE SQL EDITOR
-- =============================================================================
-- User identity: ensure users has avatar, posts/applications link to users.
-- All cards will show real user name and avatar via JOIN.
-- =============================================================================

-- 1. Users: ensure avatar column (use profile_image; add avatar_url for new uploads)
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS avatar_url text;
COMMENT ON COLUMN public.users.avatar_url IS 'Profile image URL (Supabase Storage). Prefer over profile_image when set.';

-- 2. Posts: ensure author_user_id exists and has FK to users
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS author_user_id text;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'posts_author_user_id_fkey'
  ) THEN
    ALTER TABLE public.posts
      ADD CONSTRAINT posts_author_user_id_fkey
      FOREIGN KEY (author_user_id) REFERENCES public.users(id);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_posts_author_user_id ON public.posts(author_user_id);

-- 3. Applications: ensure applicant_user_id exists and has FK to users
ALTER TABLE public.applications ADD COLUMN IF NOT EXISTS applicant_user_id text;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'applications_applicant_user_id_fkey'
  ) THEN
    ALTER TABLE public.applications
      ADD CONSTRAINT applications_applicant_user_id_fkey
      FOREIGN KEY (applicant_user_id) REFERENCES public.users(id);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_applications_applicant_user_id ON public.applications(applicant_user_id);

COMMENT ON COLUMN public.posts.author_user_id IS 'Author user id (users.id). Join users for name and avatar.';
COMMENT ON COLUMN public.applications.applicant_user_id IS 'Applicant user id (users.id). Join users for name and avatar.';
