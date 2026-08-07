-- =============================================================================
-- Migration 101 — email uniqueness that cannot lock out a phone-only user
-- =============================================================================
-- REPLACES `users_email_unique` — a plain UNIQUE (email) that exists in no
-- migration file, having been applied by hand. It was wrong in two ways that
-- both end in a user who cannot post.
--
-- 1. THE EMPTY STRING. Postgres permits many NULLs in a unique index but only
--    ONE empty string. The client wrote `email: firebaseUser.email ?? ''`, so
--    every phone-only account tried to claim `''`. The FIRST such user would
--    have taken it and EVERY subsequent phone-only signup would have failed
--    with 23505 — no `users` row, no FK target for `posts.author_user_id`, and
--    "We couldn't finish setting up your account" forever. This has not fired
--    only because production currently has zero phone-only accounts. The client
--    now omits the key entirely when the address is absent (see
--    AuthService._syncUserToSupabase); this index means a regression there can
--    no longer take the whole phone sign-up flow down with it.
--
-- 2. CASE. `Karen@Gmail.com` and `karen@gmail.com` are one mailbox and were two
--    rows — one human, two identities, which is the exact invariant this whole
--    sprint exists to defend.
--
-- WHAT IS PRESERVED: one address, one person. A NULL email means "this account
-- has no email" (phone-only), and any number of accounts may be in that state,
-- because the absence of an address is not a shared address.
--
-- SAFETY: verified before applying — zero rows with a duplicate lower(email),
-- zero rows with email = '', zero rows with NULL email. The index therefore
-- builds without conflict.
--
-- Rollback:
--   DROP INDEX IF EXISTS public.users_email_unique;
--   ALTER TABLE public.users ADD CONSTRAINT users_email_unique UNIQUE (email);
-- =============================================================================

ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_email_unique;
DROP INDEX IF EXISTS public.users_email_unique;

CREATE UNIQUE INDEX users_email_unique
  ON public.users (lower(email))
  WHERE email IS NOT NULL AND email <> '';

COMMENT ON INDEX public.users_email_unique IS
  'One mailbox, one person. Case-insensitive. NULL and '''' are excluded so a '
  'phone-only account (which has no address) never collides with another.';
