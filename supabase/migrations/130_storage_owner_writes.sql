-- 130 — a profile photo can only be written by its owner, and the public
-- post-images bucket only takes the images the app actually sends.
--
-- Found in the 2026-10-29 pre-launch audit (read-only):
--   * profiles: profiles_upload / profiles_update are TO anon, authenticated
--     with no owner check, and "Allow authenticated uploads/updates/deletes"
--     only check the bucket. So anyone holding the publishable key (it ships in
--     the APK) could overwrite any member's avatar at {uid}/avatar.jpg — the
--     path is predictable — and any signed-in member could delete it.
--   * The two "own profile image" policies compare the folder with auth.uid(),
--     which casts the JWT sub to uuid. Our subs are Firebase uids, so those two
--     can never match a member; they are replaced, not kept.
--   * post-images: anyone may upload anything, with no size limit
--     (file_size_limit is null) — free public file hosting under our domain.
--
-- What the app does (mobile-app/lib/services/storage_service.dart):
--   * avatars: profiles/{users.id}/avatar.jpg, image/jpeg, upsert, ≤ 5 MB,
--     uploaded from the profile editor (long after the session exchange).
--   * post photos: post-images/posts/{uuid}.{ext}, image/jpeg|png|gif|webp,
--     ≤ 5 MB.
-- Live objects match (2026-10-29): 11 avatars, each under its owner's Firebase
-- uid, all image/jpeg; 47 post photos, jpeg/png/webp, largest 549 KB.
--
-- Deliberately NOT changed: who may upload to post-images. Post photos are
-- uploaded during post creation, and a Storage refusal is not the 401 that
-- HttpClientWithToken re-exchanges and replays, so tightening it needs the
-- client to establish its session first. The limits below take away the
-- abuse (arbitrary types, unbounded size) without that risk.
--
-- After applying, verify on a device: change the profile photo (succeeds), and
-- as one test account try to write another test account's {uid}/avatar.jpg
-- (refused). Reversible: the rollback block at the end.

-- ── profiles: owner-only writes; reads stay public ──────────────────────────
drop policy if exists profiles_upload on storage.objects;
drop policy if exists profiles_update on storage.objects;
drop policy if exists "Allow authenticated uploads" on storage.objects;
drop policy if exists "Allow authenticated updates" on storage.objects;
drop policy if exists "Allow authenticated deletes" on storage.objects;
drop policy if exists "Users can upload their own profile image" on storage.objects;
drop policy if exists "Users can update their own profile image" on storage.objects;

drop policy if exists profiles_insert_own on storage.objects;
create policy profiles_insert_own on storage.objects
  for insert to authenticated
  with check (bucket_id = 'profiles' and (storage.foldername(name))[1] = (select auth.jwt() ->> 'user_id'));

drop policy if exists profiles_update_own on storage.objects;
create policy profiles_update_own on storage.objects
  for update to authenticated
  using (bucket_id = 'profiles' and (storage.foldername(name))[1] = (select auth.jwt() ->> 'user_id'))
  with check (bucket_id = 'profiles' and (storage.foldername(name))[1] = (select auth.jwt() ->> 'user_id'));

drop policy if exists profiles_delete_own on storage.objects;
create policy profiles_delete_own on storage.objects
  for delete to authenticated
  using (bucket_id = 'profiles' and (storage.foldername(name))[1] = (select auth.jwt() ->> 'user_id'));

-- profiles_read, "Public read access" and "Public can view profile images"
-- (SELECT, everyone) are unchanged: avatars are public.

-- ── Bucket limits: what the app sends, nothing else ─────────────────────────
-- profiles already has these (5 MB; jpeg/png/gif/webp). post-images had none.
update storage.buckets
   set file_size_limit = 5242880,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/gif', 'image/webp']
 where id = 'post-images';

-- ── Rollback (run by hand only) ─────────────────────────────────────────────
-- drop policy profiles_insert_own on storage.objects;
-- drop policy profiles_update_own on storage.objects;
-- drop policy profiles_delete_own on storage.objects;
-- create policy profiles_upload on storage.objects for insert to anon, authenticated with check (bucket_id = 'profiles');
-- create policy profiles_update on storage.objects for update to anon, authenticated using (bucket_id = 'profiles') with check (bucket_id = 'profiles');
-- create policy "Allow authenticated uploads" on storage.objects for insert to authenticated with check (bucket_id = 'profiles');
-- create policy "Allow authenticated updates" on storage.objects for update to authenticated using (bucket_id = 'profiles');
-- create policy "Allow authenticated deletes" on storage.objects for delete to authenticated using (bucket_id = 'profiles');
-- create policy "Users can upload their own profile image" on storage.objects for insert to authenticated
--   with check (bucket_id = 'profiles' and (auth.uid())::text = (storage.foldername(name))[1]);
-- create policy "Users can update their own profile image" on storage.objects for update to authenticated
--   using (bucket_id = 'profiles' and (auth.uid())::text = (storage.foldername(name))[1]);
-- update storage.buckets set file_size_limit = null, allowed_mime_types = null where id = 'post-images';
