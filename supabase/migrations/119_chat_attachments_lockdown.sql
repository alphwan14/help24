-- 119 — Close the old public path for chat attachments.
--
-- APPLY ONLY AFTER ALL OF:
--   1. the app release that uploads through files.help24.co.ke (1.0.2+3) is
--      downloadable, and ops.min_version.hard is set to it;
--   2. scripts/storage/migrate-chat-attachments.mjs --apply has run and
--      --verify reports 0 failures (every attachment row is a private ref).
-- Before that, part A would stop every user still on 1.0.1 from sending a
-- photo or document, and part C could stop their uploads too.
--
-- A. Every attachment row must name its OWN object in the private bucket.
--    Builds up to 1.0.1 write the public URL of a file they uploaded to
--    post-images; this refuses that row, so an old build that has not been
--    restarted since the minimum version moved cannot put a chat file back on
--    a public address. Added as one validating statement (the table is small),
--    after a guard that aborts the whole migration if any row is unmigrated —
--    so it can never be left half-applied, with a NOT VALID constraint
--    blocking updates (moderation hide/restore, delete-for-everyone) on rows
--    that do not comply.
--
-- Apply as ONE transaction (apply_migration does; psql: --single-transaction).
--
-- B. No more chat files in post-images: a RESTRICTIVE policy (ANDed with the
--    existing permissive "anyone can upload to post-images" policies) refuses
--    any insert under chat_attachments/. Marketplace uploads (posts/, avatars/)
--    are untouched.
--
-- C. Nothing may list or read chat_attachments/ through the API any more
--    (closes the enumeration the publishable key allowed). Public URLs of
--    objects still there keep working until those objects are deleted —
--    that is what --delete-legacy is for, and it needs its own approval.
--
-- The service role (Worker, backend, migration tool) bypasses RLS and is
-- unaffected by B and C.
--
-- ROLLBACK:
--   alter table public.chat_messages drop constraint if exists chat_messages_attachment_is_private_ref;
--   drop policy if exists "chat attachments are not stored in post-images" on storage.objects;
--   drop policy if exists "chat attachments are not listed from post-images" on storage.objects;

-- A ──────────────────────────────────────────────────────────────────────────
do $$
declare
  unmigrated integer;
begin
  select count(*) into unmigrated
    from public.chat_messages
   where not (
     attachment_url is null
     or (type in ('image', 'file')
         and attachment_url ~ ('^chat-attachments/' || chat_id::text || '/' || id::text || '\.(jpg|png|gif|webp|pdf|doc|docx)$'))
   );
  if unmigrated > 0 then
    raise exception 'HELP24_119_NOT_READY: % chat_messages row(s) still carry a non-private attachment reference — run migrate-chat-attachments.mjs --apply first', unmigrated;
  end if;
end $$;

alter table public.chat_messages
  add constraint chat_messages_attachment_is_private_ref check (
    attachment_url is null
    or (
      type in ('image', 'file')
      and attachment_url ~ (
        '^chat-attachments/' || chat_id::text || '/' || id::text
        || '\.(jpg|png|gif|webp|pdf|doc|docx)$'
      )
    )
  );

-- B ──────────────────────────────────────────────────────────────────────────
create policy "chat attachments are not stored in post-images"
  on storage.objects
  as restrictive
  for insert
  to public
  with check (bucket_id <> 'post-images' or name not like 'chat_attachments/%');

-- C ──────────────────────────────────────────────────────────────────────────
create policy "chat attachments are not listed from post-images"
  on storage.objects
  as restrictive
  for select
  to public
  using (bucket_id <> 'post-images' or name not like 'chat_attachments/%');

-- Verification (read-only):
--   select convalidated from pg_constraint where conname = 'chat_messages_attachment_is_private_ref';  -- true
--   select policyname, permissive, cmd from pg_policies where schemaname = 'storage' and policyname like 'chat attachments%';
--   -- With the publishable key, POST /storage/v1/object/list/post-images {"prefix":"chat_attachments/"} → []
