-- 123 — public_profiles carries everything the app shows about OTHER people.
--
-- Step 1 of the users-table lockdown (2026-10). Today public.users is readable
-- by anyone holding the publishable key, so every client can list every
-- member's email and phone number. The lockdown will make public.users
-- readable only by the row's owner. Before that can happen, every read of
-- SOMEONE ELSE has to come from here instead — so this view must carry the
-- public fields those reads show: profession, bio, member-since, presence.
--
-- Still deliberately absent: email and phone_number. `has_phone` (already
-- here) is all anyone else needs — the "M-Pesa" badge and the
-- provider-has-a-payout-number check.
--
-- The view runs with its owner's rights (it is not security_invoker), so it
-- keeps working when public.users RLS is tightened. Additive only: the four
-- existing columns keep their names, types and order, so every current reader
-- (the app's saved-posts screen) is unaffected.
--
-- Reversible:
--   create or replace view public.public_profiles as
--     select id, name,
--            coalesce(nullif(avatar_url, ''), nullif(profile_image, '')) as avatar_url,
--            phone_number is not null and phone_number <> '' as has_phone
--     from public.users;
-- (Postgres cannot drop columns from a view with CREATE OR REPLACE; restoring
--  the old shape means DROP VIEW then the statement above, and re-granting.)

create or replace view public.public_profiles as
select
  id,
  name,
  coalesce(nullif(avatar_url, ''), nullif(profile_image, '')) as avatar_url,
  phone_number is not null and phone_number <> '' as has_phone,
  -- Appended, never reordered (CREATE OR REPLACE VIEW only allows appending).
  nullif(profile_image, '') as profile_image,
  profession,
  bio,
  created_at,
  last_seen,
  is_online
from public.users;

grant select on public.public_profiles to anon, authenticated;
