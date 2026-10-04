-- 118 — Private bucket for chat attachments.
--
-- WHY
-- Chat photos and documents were stored in the PUBLIC `post-images` bucket under
-- chat_attachments/<chat>/<file>, and each message kept the permanent public
-- URL. Anyone with a URL could download the file forever; deleting a message
-- "for everyone" left its file online; and the app's publishable key could
-- LIST every chat folder (verified 2026-10-03), so any conversation's files
-- were enumerable by someone who was never in it.
--
-- WHAT
-- A separate PRIVATE bucket. There are deliberately NO storage.objects
-- policies for it: no role a phone or browser can hold (anon, authenticated)
-- may select, list, insert, update or delete anything in it. The only reader
-- and writer is the files Worker (workers/help24-files, files.help24.co.ke),
-- which uses the service key after checking that the caller is a participant
-- of the message's chat. Admins read through ten-minute signed links minted by
-- the backend (ChatAttachmentLinksService).
--
-- Limits mirror the app and the Worker: 10 MB; JPEG, PNG, GIF, WebP, PDF,
-- DOC, DOCX.
--
-- `post-images` is NOT changed here: marketplace photos must stay public.
-- Locking the old chat_attachments/ prefix down is migration 119, which must
-- wait until the app release that stops using it is downloadable.
--
-- No table changes. chat_messages.attachment_url keeps its column; new rows
-- carry the private reference `chat-attachments/<chat_id>/<id>.<ext>` instead
-- of a public URL.
--
-- APPLY: safe at any time — nothing reads this bucket until the Worker and the
-- new app use it. Idempotent.
--
-- ROLLBACK (only while the bucket is empty):
--   delete from storage.buckets where id = 'chat-attachments';

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'chat-attachments',
  'chat-attachments',
  false,
  10485760,
  array[
    'image/jpeg',
    'image/png',
    'image/gif',
    'image/webp',
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  ]
)
on conflict (id) do update
  set public             = false,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Verification (read-only):
--   select id, public, file_size_limit, allowed_mime_types from storage.buckets where id = 'chat-attachments';
--   -- must return zero rows: no policy may mention the bucket
--   select policyname from pg_policies
--    where schemaname = 'storage' and tablename = 'objects'
--      and (coalesce(qual, '') || coalesce(with_check, '')) like '%chat-attachments%';
