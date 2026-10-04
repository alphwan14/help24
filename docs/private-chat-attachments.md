# Private chat attachments (files.help24.co.ke)

Chat photos and documents are private to the two people in the conversation.
This page is the contract: what is stored where, who can read it, how the app,
the browser and Trust & Safety get at a file, and the order the change rolls out.

## What was wrong (found 2026-10-03)

- Chat files lived in the **public** `post-images` bucket at
  `chat_attachments/<chat>/<file>`; each message stored the permanent public URL.
- Anyone with a URL could download the file forever. Deleting a message
  "for everyone" left the file online.
- The publishable key shipped in the APK could **list** every chat folder, so
  any conversation's files were enumerable by a stranger.
- The bucket accepted anonymous uploads of any type and size.

## The model now

```
 app ──PUT /u/<chat>/<msg>──▶ files.help24.co.ke ──service key──▶ chat-attachments (private)
 app ──GET /d/<msg>────────▶   (Cloudflare Worker)                 bucket, no policies
 app ──POST /links/<msg>──▶       checks: Firebase token,
 browser ──GET /d/<msg>?t=…──▶     participant of the row's chat,
                                    not deleted for everyone
 admin dashboard ──▶ backend (admin-only) ──▶ 10-minute signed link
```

- **Storage.** Bucket `chat-attachments`: private, 10 MB, JPEG/PNG/GIF/WebP/PDF/DOC/DOCX,
  and *no* `storage.objects` policies — no phone or browser role can touch it
  (migration 118). Marketplace photos stay public in `post-images`.
- **Reference, not address.** `chat_messages.attachment_url` holds
  `chat-attachments/<chat_id>/<message_id>.<ext>`. No new table, no new column.
- **Objects live in their uploader's folder:** `<chat_id>/<uploader uid>/<message_id>.<ext>`.
  `chat_messages` RLS lets either participant insert or edit a row with *any*
  `sender_id` in their chat (pre-existing, unchanged), so without this A could
  upload a file and attach it to a row "from B". A read derives the key from
  the row's `sender_id`, so only what the sender uploaded is ever served as theirs.
- **One rule for which object a message may name** (`workers/help24-files/src/policy.js`,
  mirrored in `backend/src/moderation/chat-attachment-links.service.ts`): the key is
  derived from the row's *own* `chat_id`, `sender_id` and `id`; the stored
  reference contributes only the extension, and only if it names that same chat
  and message. A client that writes someone else's key into its own row gets nothing.
- **Participants only.** The Worker loads the message with the service key and
  requires the caller's Firebase uid to be `chats.user1` or `user2` of that row's
  chat. RLS (`chats_participant`, `chat_messages_participant`) means only a
  participant can change those columns or move a message between chats.
  Not-a-participant and no-such-message are the same byte-for-byte 404.
- **Deleted for everyone → 410.** The flag cannot be reversed
  (`trg_chat_messages_undelete_guard`).
- **No proxy.** Three routes, ids must be uuids, the bucket and key are never
  taken from the request, upstream headers are never forwarded, Supabase errors
  become a bare 503.
- **Content checks on upload.** Declared type must be on the allowlist and the
  bytes must match it (magic bytes). Served `Content-Type` comes from the
  extension, with `nosniff`; everything but PDFs also gets a sandboxing CSP.
- **Never overwritten.** Uploads use `x-upsert: false`. A retry of the same
  message gets "already stored" — the offline outbox relies on this.
- **Rate-limited.** 20 uploads and 20 browser links per user per minute (429 beyond).

### In the app

- `lib/services/chat_attachments.dart`: reference rules, `/d/<id>` URL,
  `ChatAttachmentApi.upload` (120 s timeout, through `Help24ApiClient`, so the
  Firebase token is attached and refreshed on `TOKEN_EXPIRED`),
  `ChatAttachmentApi.browserLink`, and `ChatAttachmentCache` — a separate
  image cache whose downloads carry the token, keyed `chat-attachment:<id>`,
  emptied at sign-out.
- Outbox (`outbox_delivery.dart`): an attachment must have a uuid message id;
  anything but this message's private reference is (re)uploaded first — which
  is what rescues a photo a 1.0.1 build queued with a public URL.
  `sendAttachmentMessage` refuses any non-private reference.
- Documents behave like photos (`lib/services/chat_documents.dart`): the first
  tap downloads `GET /d/<id>` once, with the token, into app-private storage at
  `filesDir/chat_documents/<id>/<filename>` (written to a `.part-…` file and
  renamed only when complete; only PDF/Word types; 100 MB cache, least recently
  opened pruned first). Every later tap — offline included — opens the local
  file with no request. Android hands it to a viewer through a non-exported
  `FileProvider` (`<package>.documents`, only `chat_documents/`) as a
  `content://` URI with a one-file read grant; the native side refuses any path
  outside that folder.
- The **one-time link** is now only the fallback when the phone has no app that
  opens the type: the app POSTs `/links/<id>`, gets
  `https://files.help24.co.ke/d/<id>?t=…` (2 minutes, single use — burnt in a
  Durable Object, so exactly one of any number of simultaneous uses succeeds),
  the Worker burns it, sets an HttpOnly cookie scoped to `/d/<id>` for 10
  minutes, and 303s to the clean URL. The link and cookie carry a keyed tag of
  the uid, never the uid; membership and deletion are re-checked on every request.
- **Deleted for everyone** removes every local copy — the cached photo (disk and
  decoded memory) and the cached document — whenever the deletion reaches the
  phone: by realtime, a fresh page, the thread cache, after coming back online,
  or the user's own action. A 410 from `/d` does the same. Sign-out removes
  every cached document along with the photo cache.

### Trust & Safety

`GET /admin/moderation/reports/:id` (AdminAuthGuard, `support_agent`) returns
`attachment_view_url` — a 10-minute signed link from the backend — for the
reported message (live and as snapshotted) and for each conversation message.
The dashboard renders only that, never `attachment_url`. Report snapshots keep
the reference as filed; they resolve to the private copy by chat + message id,
so nothing in `user_reports` is rewritten. Admins can still see attachments of
messages deleted for everyone, as they can already see their text.

## Rollout order

Each production step needs its own approval.

| # | Step | Effect on users still on ≤ 1.0.1 |
|---|------|------|
| 1 | Apply migration 118 (create private bucket) | none |
| 2 | Deploy the Worker (DEPLOY.md) | none |
| 3 | Publish the app release containing this (≥ **1.0.2+3**) | none |
| 4 | `migrate-chat-attachments.mjs --apply`, then `--verify` | their chats show existing photos/documents as "Couldn't load" |
| 5 | Set `ops.min_version.hard` = `1.0.2` (below) | blocked at next cold start, sent to /download |
| 6 | Apply migration 119 (lockdown) | any not yet restarted can no longer send attachments |
| 7 | `--delete-legacy --include-orphans --confirm-delete N` | old public URLs stop working |

Until step 7, the old objects are still reachable at their public URLs and
(until 119) listable — the exposure is only closed at 6–7.

### Minimum version

Released builds that expect public URLs: **1.0.0** (versionCode 1, still
downloadable) and **1.0.1** (versionCode 2, Latest). Both upload to
`post-images` and render `attachment_url` directly. The first build that works
with private attachments is the next release, **1.0.2** (versionCode 3).
Set it only once 1.0.2 is downloadable from /download:

```sql
update public.app_settings
   set value = jsonb_build_object(
         'hard', '1.0.2',
         'soft', '1.0.2',
         'message', 'This version of Help24 can no longer open chat photos and documents. Update to keep chatting.',
         'store_url', 'https://help24.co.ke/download'),
       updated_at = now()
 where key = 'ops.min_version';
```

The backend caches config for 60 s; the hard gate applies at the app's next
cold start.

## Verifying

- `workers/help24-files`: `node --test "test/*.test.js"` (unit + security),
  `scripts/live-security-test.mjs` (live data; `--identity local` is read-only).
- `scripts/storage/migrate-chat-attachments.mjs --verify` (read-only);
  its rules — above all what `--delete-legacy` may delete — are tested with
  `node --test "scripts/storage/test/*.test.mjs"`.
- Flutter: `test/chat_attachments_test.dart`, `test/chat_documents_test.dart`,
  `test/offline_attachment_outbox_test.dart`.
- Backend: `src/moderation/investigation.service.spec.ts`.

## Known limits

- Firebase token revocation is not checked (same as the backend): a revoked
  session keeps access to its own chats' files until its token expires (≤ 1 h).
- A participant can rewrite the other participant of their own chat
  (`chats_participant` RLS allows it) and so hand the conversation's files to a
  third person — equivalent to forwarding them, and pre-existing.
- `chat_messages_participant` lets a participant insert rows as, or edit, the
  other person's messages — text included. Attachments are protected by the
  uploader folder above; text is not. Pre-existing; not changed here, and worth
  its own fix (bind `sender_id` to the JWT on insert, forbid editing others' rows).
- Uploads whose message never arrives stay in the bucket (no sweeper — see DEPLOY.md).
- PDFs are served without a CSP so Chrome's viewer can render them. Framing one
  from another site is pointless: the document cookie is `SameSite=Lax`, so a
  cross-site frame gets the "link expired" page.

## Open follow-up: first open of a large document

Opening a document the phone already has is fixed: every tap after the first
opens the local copy in about 0.15 s with no request at all. The **first**
download of a large file is still slow, and that is an open investigation, not
a closed one.

Measured on the S20+ on 2026-10-04 with the same 9 MB PDF (8,880,626 B):

| | First open | Repeat open |
|---|---|---|
| Before (one-time link → Chrome) | ~8.9–9.2 s | the same again — every tap re-downloaded |
| Now (`GET /d` → app-private cache → viewer) | **~18–19 s** (sent and received) | **~0.12–0.16 s**, 0 Worker requests |

What the measurements say so far:

- The app's download ran through Cloudflare's Lagos location (`LOS`) on both
  first opens. The phone's own `curl` of the same file through the same host
  took 7.1 s and 14.5 s on two runs (`MPM`); the PC measured 12–14.5 Mbit/s on
  one stream, and four parallel ranges were no faster. The route varies a lot
  from minute to minute (LOS, MPM, GVA, PRG and PDX all served this phone or PC
  within an hour) and nothing here was measured side by side.
- So the slowdown is not proven to be the app. It is not proven not to be,
  either: an app-vs-`curl` comparison on the phone, at the same moment through
  the same location, has not been run.

If people report slow first opens of big documents, resume from here: run that
side-by-side measurement first (`wrangler tail --format json` gives the
location and Worker wall time per request; the S20+ recipe is in the session
notes). Do not redesign the cache to chase it — the private local cache is what
makes every later open instant and offline-capable — and do not add speculative
tuning (parallel ranges, buffer sizes) without that measurement.
