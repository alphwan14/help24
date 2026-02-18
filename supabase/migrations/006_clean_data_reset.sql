-- =============================================================================
-- CLEAN DATA RESET — run in Supabase SQL Editor when you want a fresh start
-- =============================================================================
-- Deletes ALL ROWS from messaging and content tables. Does NOT drop tables.
-- Order respects foreign keys (messages → conversations; applications/post_images → posts).
-- =============================================================================

-- 1. Messages (references conversations)
DELETE FROM public.messages;

-- 2. Conversations
DELETE FROM public.conversations;

-- 3. Applications (references posts)
DELETE FROM public.applications;

-- 4. Post images (references posts)
DELETE FROM public.post_images;

-- 5. Posts (requests, jobs, offers — all live in this table)
DELETE FROM public.posts;

-- 6. Users
DELETE FROM public.users;

-- Optional: reset sequences if you use serials (e.g. for ids)
-- SELECT setval(pg_get_serial_sequence('public.posts', 'id'), 1);

COMMENT ON TABLE public.users IS 'Cleaned; re-populated on next sign-up/sign-in.';
