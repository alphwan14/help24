-- 129 — the publishable key reads public listings and nothing private, and
-- writes nothing in anyone else's name.
--
-- Found in the 2026-10-29 pre-launch audit, by calling PostgREST with only the
-- publishable key (it ships inside the APK):
--
--   * notifications: 320 rows for 10 members were readable, 216 of them
--     chat_message notifications whose body is the message text (189 matched
--     a real chat message). notifications_anon_update (USING true) also let the
--     same caller rewrite any of them — title, body and the data payload a tap
--     navigates by. Both policies came from 041, on the reasoning that "the app
--     always filters by user_id". A client-side filter is not access control.
--   * providers: both rows, with phone_login and phone_payout, were readable
--     by anyone. (Its ALL policy for authenticated never let anyone write: that
--     role only holds SELECT.) Only the backend uses this table, with the
--     service role.
--   * posts / post_images / applications: anyone could insert a post, an image
--     row or an application in any member's name (WITH CHECK true), and delete
--     every post_images row (USING true).
--   * messages (legacy, 0 rows, read by nothing): any signed-in member could
--     read and insert anything.
--
-- What made it safe to close (all verified before applying):
--   * Every supported app (ops.min_version.hard = 1.0.4) sends its reads and
--     writes through HttpClientWithToken, which on a 401 re-exchanges the
--     Firebase token once and replays the request (present at 899bbf9 = 1.0.4,
--     5641360 = 1.0.5, 5e1edcd = 1.0.8). So a request that leaves before the
--     exchange is REFUSED (401, the grant is revoked below), re-authenticated
--     and replayed, instead of quietly answered with an empty list. That is why
--     the grants are revoked and not only the policies: with the grant kept an
--     early anon read would return 200 [] and the bell would say "nothing new".
--   * The app inserts posts with author_user_id = the signed-in uid, image rows
--     only for the post it just created, applications with applicant_user_id =
--     the signed-in uid, and never deletes post_images rows itself (the posts FK
--     cascade does that, and cascades are not subject to RLS).
--   * The backend, admin dashboard and partner portal use the service role.
--   * No view or caller-rights function reads notifications, providers or
--     post_images with the caller's rights (pre-flight, 2026-10-29); the one
--     view over posts/applications (partner_member_progress) only SELECTs,
--     which is unchanged.
--
-- Deliberately NOT changed here:
--   * SELECT on posts, post_images and applications stays open: logged-out
--     browsing reads posts and images, and Discover cards count applicants
--     from the embedded applications rows. Narrowing applications SELECT needs
--     an app release that reads the count from somewhere else first.
--   * The profiles storage bucket (any caller can overwrite any avatar) — it
--     is storage, not a table, and is its own migration.
--
-- Reversible: the rollback block at the end restores every policy and grant
-- exactly as they were on 2026-10-29.

-- ── notifications: your own, signed in ──────────────────────────────────────
-- notifications_owner_read / notifications_owner_update (authenticated,
-- user_id = jwt user_id) and notifications_service_role are unchanged.
drop policy if exists notifications_anon_read on public.notifications;
drop policy if exists notifications_anon_update on public.notifications;
revoke select, update on public.notifications from anon;

-- ── providers: backend only ─────────────────────────────────────────────────
do $$ begin
  if to_regclass('public.providers') is not null then
    drop policy if exists "Enable all access for authenticated users" on public.providers;
    drop policy if exists "Enable read access for all users" on public.providers;
    revoke all on public.providers from anon, authenticated;
  end if;
end $$;

-- ── messages (legacy): participants only ────────────────────────────────────
-- messages_participant (authenticated, sender or receiver) is unchanged.
do $$ begin
  if to_regclass('public.messages') is not null then
    drop policy if exists messages_insert on public.messages;
    drop policy if exists messages_select on public.messages;
    revoke truncate, trigger, references on public.messages from authenticated;
  end if;
end $$;

-- ── posts: create in your own name, signed in ───────────────────────────────
-- posts_select (everyone), posts_update_owner and posts_delete_owner are
-- unchanged.
drop policy if exists posts_insert on public.posts;
drop policy if exists posts_insert_own on public.posts;
create policy posts_insert_own on public.posts
  for insert to authenticated
  with check (author_user_id = (select auth.jwt() ->> 'user_id'));
revoke insert, truncate, trigger, references on public.posts from anon;
revoke truncate, trigger, references on public.posts from authenticated;

-- ── post_images: add to your own post, signed in; nobody deletes directly ───
-- post_images_select (everyone) is unchanged.
drop policy if exists post_images_insert on public.post_images;
drop policy if exists post_images_delete on public.post_images;
drop policy if exists post_images_insert_by_author on public.post_images;
create policy post_images_insert_by_author on public.post_images
  for insert to authenticated
  with check (exists (
    select 1 from public.posts p
    where p.id = post_id and p.author_user_id = (select auth.jwt() ->> 'user_id')
  ));
revoke insert, update, delete, truncate, trigger, references on public.post_images from anon;
revoke update, delete, truncate, trigger, references on public.post_images from authenticated;

-- ── applications: apply in your own name, signed in ─────────────────────────
-- applications_select (everyone) is unchanged — see the header.
drop policy if exists applications_insert on public.applications;
drop policy if exists applications_insert_own on public.applications;
create policy applications_insert_own on public.applications
  for insert to authenticated
  with check (applicant_user_id = (select auth.jwt() ->> 'user_id'));
revoke insert, update, delete, truncate, trigger, references on public.applications from anon;
revoke update, delete, truncate, trigger, references on public.applications from authenticated;

-- ── Rollback (run by hand only) ─────────────────────────────────────────────
-- grant select, update on public.notifications to anon;
-- create policy notifications_anon_read on public.notifications for select to anon using (true);
-- create policy notifications_anon_update on public.notifications for update to anon using (true) with check (true);
-- grant select on public.providers to anon, authenticated;
-- create policy "Enable read access for all users" on public.providers for select using (true);
-- create policy "Enable all access for authenticated users" on public.providers for all
--   using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
-- create policy messages_insert on public.messages for insert with check (true);
-- create policy messages_select on public.messages for select using (true);
-- grant truncate, trigger, references on public.messages to authenticated;
-- drop policy posts_insert_own on public.posts;
-- create policy posts_insert on public.posts for insert with check (true);
-- grant insert, truncate, trigger, references on public.posts to anon;
-- grant truncate, trigger, references on public.posts to authenticated;
-- drop policy post_images_insert_by_author on public.post_images;
-- create policy post_images_insert on public.post_images for insert with check (true);
-- create policy post_images_delete on public.post_images for delete using (true);
-- grant insert, update, delete, truncate, trigger, references on public.post_images to anon;
-- grant update, delete, truncate, trigger, references on public.post_images to authenticated;
-- drop policy applications_insert_own on public.applications;
-- create policy applications_insert on public.applications for insert with check (true);
-- grant insert, update, delete, truncate, trigger, references on public.applications to anon;
-- grant update, delete, truncate, trigger, references on public.applications to authenticated;
