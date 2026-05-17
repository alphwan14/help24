# Help24 — Production Readiness Audit

**Scope:** Supabase (auth sync, posts, jobs, applications, chats, chat_messages, storage), Flutter client, FCM.  
**Audit date:** Based on current codebase and migrations.

---

## 1. DATABASE STRUCTURE

### 1.1 Indexes (actual state)

| Table | Index | Status |
|-------|--------|--------|
| **chats** | `idx_chats_user1`, `idx_chats_user2`, `idx_chats_updated_at` | ✅ Present (008) |
| **chats** | `idx_chats_unique_null`, `idx_chats_unique_post` | ✅ Unique constraints (008) |
| **chat_messages** | `idx_chat_messages_chat_id`, `idx_chat_messages_chat_created` | ✅ Present (008) |
| **posts** | `idx_posts_author_user_id` | ✅ Present (004) |
| **applications** | `idx_applications_applicant_user_id` | ✅ Present (004) |
| **users** | Primary key `id` | ✅ No extra index needed for PK lookups |
| **conversations** (legacy) | user1_id, user2_id, updated_at | ✅ (002) — not used by current chat flow |
| **messages** (legacy) | conversation_id, (conversation_id, created_at) | ✅ (002) |

**Missing / recommended:**

- **posts**: No `created_at` index found in migrations. Queries use `.order('created_at', ascending: false)` and `.range()`. For large tables, add:  
  `CREATE INDEX IF NOT EXISTS idx_posts_created_at ON public.posts(created_at DESC);`
- **applications**: Queries filter by `post_id` (e.g. `getApplicationsForPost`, `hasApplied`, `inFilter('post_id', postIds)`). No index on `post_id` in migrations. Add:  
  `CREATE INDEX IF NOT EXISTS idx_applications_post_id ON public.applications(post_id);`
- **chat_messages**: `sender_id` is not indexed; current code does not query by sender_id alone. Optional for future:  
  `CREATE INDEX IF NOT EXISTS idx_chat_messages_sender_id ON public.chat_messages(sender_id);`

**Note:** The `posts` table definition is not present in the migration set (only ALTER in 004, DELETE in 006). Ensure `posts` has a `created_at` column and consider the index above once the table exists.

### 1.2 Full-table scans

- **Posts/jobs:** `PostService.fetchPosts` / `fetchJobs` use filters (type, category, location, etc.) and `.order('created_at').range(offset, offset+limit-1)`. With an index on `created_at` (and possibly composite with `type` for jobs), these are not full-table scans.
- **Chat list:** `_fetchConversations` uses `.or('user1.eq.$currentUserId,user2.eq.$currentUserId').order('updated_at')`. Indexes on `user1` and `user2` support this; no full-table scan.
- **Chat messages:** `getMessages(chatId)` uses `.eq('chat_id', chatIdParam).order('created_at')`. `idx_chat_messages_chat_created` supports this; no full-table scan for that query.
- **Applications:** `.eq('post_id', postId)` and `.eq('applicant_user_id', currentUserId)` need `post_id` and `applicant_user_id` indexes; `applicant_user_id` exists, `post_id` is missing (see above).

### 1.3 Pagination

| Feature | Implementation | Verdict |
|---------|----------------|---------|
| **Posts** | `PostFilters(limit: 50, offset: 0)`; `query.range(offset, offset+limit-1)` in `post_service.dart` | ✅ Pagination implemented. UI always passes default filters (no offset/limit from app_provider), so only first 50 posts load. |
| **Jobs** | Same as posts: `range(offset, offset+limit-1)` with default limit 50 | ✅ Pagination implemented. Same as above: first page only in UI. |
| **Conversations** | `_fetchConversations`: no `.limit()` or `.range()` | ❌ **No pagination.** All chats for the user are fetched. |
| **Chat messages** | `getMessages(chatId)`: no `.limit()` or `.range()` | ❌ **No pagination.** All messages for the chat are fetched. |
| **Applications** | `getApplicationsForPost`, `getMyApplications`: no limit | ⚠️ No pagination; acceptable for small per-post counts; add limit/offset for scale. |

**Critical:** For 10k+ users and long-lived chats, add cursor- or offset-based pagination for:
1. **Conversations list** (e.g. limit 50, order by `updated_at DESC`).
2. **Chat messages** (e.g. initial load last N, then “load older” with cursor on `created_at`).

---

## 2. REALTIME USAGE

- **Supabase Realtime:** The app does **not** subscribe to Supabase Realtime for `chats` or `chat_messages`. `ChatServiceSupabase` uses polling (conversations every 15s; messages every 4s in `ChatScreen`). So there are **no full-table Realtime subscriptions**.
- **Legacy:** `message_service.dart` has `subscribeToMessages(conversationId)` for the old `conversations`/`messages` schema, scoped by `conversationId`. That path is not used by the current chat flow (which uses `chat_service_supabase.dart`).
- **Verdict:** Realtime is not used for current messaging; no table-wide subscriptions. When you enable Realtime (e.g. for `chat_messages`), scope by `chat_id` (e.g. filter in channel) so each client only receives messages for the chats it cares about.

---

## 3. STORAGE

- **Profile images:** Stored in bucket `profiles` with path `{user_id}/avatar.jpg` (see `storage_service.dart`: `uploadProfileImageToProfilesBucket` → `filePath = '$userId/$fileName'`, `fileName = 'avatar.jpg'`). Not `profiles/{user_id}.jpg`; structure is `{user_id}/avatar.jpg` inside the `profiles` bucket. Public URL via `getPublicUrl(filePath)`. ✅ Consistent and efficient.
- **Bucket config (009):** `profiles` bucket: public, 5MB limit, image MIME types. ✅
- **Post images:** `post-images` bucket, path `posts/{uuid}.{ext}`. ✅
- **Compression:** Profile upload checks `bytes.length > maxFileSize` (5MB). No client-side image compression (resize/quality) before upload; `edit_profile_screen` uses `image_picker` with `maxWidth: 512, imageQuality: 85` for the picked file. ✅ Partial; consider enforcing max dimensions/quality in one place (e.g. storage service) for all profile uploads.
- **Verdict:** Storage paths and public URL usage are fine. Add consistent compression/resize for profile uploads if not already guaranteed.

---

## 4. AUTH & RLS

### 4.1 Current RLS (from migrations)

- **users (001):** SELECT/INSERT/UPDATE for `anon` and `authenticated` with `USING (true)` / `WITH CHECK (true)`. Any client with the anon key can read/update any user row.
- **chats (008):** Same: SELECT/INSERT/UPDATE for `anon` and `authenticated` with `USING (true)` / `WITH CHECK (true)`.
- **chat_messages (008):** Same: SELECT/INSERT/UPDATE for `anon` and `authenticated` with `USING (true)` / `WITH CHECK (true)`.

Supabase is initialized with the **anon key only** (`supabase_config.dart`). There is no `supabase.auth.setSession()` or Supabase JWT derived from Firebase. So all requests are effectively “anon” (or a single role); Supabase does not know the current user. RLS cannot restrict by `auth.uid()` because the session is not user-specific.

### 4.2 Implications

- **No client-side bypass of RLS:** RLS is permissive by design; there is no stricter policy to bypass.
- **Security:** Any holder of the anon key can read/update all users, chats, and chat_messages. For production this is a **structural weakness**. Mitigations:
  1. **Option A:** Use Supabase Auth with a custom JWT (e.g. sign a JWT with Firebase UID and use as Supabase session) so RLS can use `auth.uid()` and restrict rows by user.
  2. **Option B:** Keep anon key and add RLS policies that restrict using a custom claim or header (if you introduce a backend that sets them). Without that, application-level checks (e.g. “only sender can send in this chat”) are the only protection and can be bypassed by a modified client.

### 4.3 Queries and session

- All services use `SupabaseConfig.client` (anon). No use of `auth.getUser()` or `auth.getSession()` for Supabase. Firebase Auth is used for identity in the app; that identity is not reflected in Supabase RLS with the current setup.

---

## 5. CLIENT PERFORMANCE (Flutter)

- **Rebuilds:** Provider usage is scoped (e.g. `Consumer<AppProvider>`, `Consumer2<AppProvider, ConnectivityProvider>`). List views use `ListView.builder` (Discover, Jobs, Messages). No obvious unnecessary full-tree rebuilds.
- **State management:** Single `AppProvider` for posts, jobs, conversations; `AuthProvider`; `ConnectivityProvider`. Clear ownership.
- **Listeners / subscriptions:**
  - `AppProvider.loadConversations`: subscribes to `ChatServiceSupabase.watchConversations(currentUserId).listen(...)`. `stopListeningToConversations()` exists but is only called from `AppProvider`; it is **not** called when the user leaves the Messages tab (e.g. from `HomeScreen` or `MessagesScreen`). So the conversation polling (15s timer) can keep running. Prefer calling `stopListeningToConversations()` when the user navigates away from the Messages tab (or when the app is paused) to avoid unnecessary work.
  - `AuthProvider`: `AuthService.authStateChanges.listen`; cancelled in `dispose()`. ✅
  - `ConnectivityProvider`: `Connectivity().onConnectivityChanged.listen`; has `dispose()`. ✅
- **Dispose:** Controllers and timers are disposed in the relevant `State` classes (e.g. `_ChatScreenState`, `_MessagesScreenState`, auth screens, application_modal, edit_profile). `_pollTimer` and `_liveLocationSubscription` in ChatScreen are cancelled in `dispose()`. ✅
- **Lists and pagination:** Discover/Jobs show the first 50 posts/jobs (single page). No “load more” or cursor; that’s acceptable for 50–10k users. For 1M+ posts, the UI should request next pages (offset or cursor) and append to the list.

**Verdict:** No infinite listeners in the sense of unbounded growth; one improvement is to stop conversation polling when the user leaves the Messages surface. Lists are bounded by backend pagination (50) but UI does not yet support “load more.”

---

## 6. PUSH NOTIFICATIONS (FCM)

- **Client:** `NotificationService` (Firebase Messaging) handles permission, token, and saving the token to Supabase `users.fcm_tokens` via `UserProfileService.addFcmToken`. Tap handling and navigation to chat are implemented in `main.dart` using `data.chatId`. ✅ Client-side FCM is receive-only and does not send pushes.
- **Server:** There is **no** Supabase Edge Function or other server-side trigger in the repo that sends FCM when a row is inserted into `chat_messages`. The notification_service comments describe the intended flow (resolve recipient, read `fcm_tokens` and `notifications_enabled` from `users`, send FCM with title/body/data.chatId), but that logic is **not implemented** in the codebase.
- **Verdict:** FCM is triggered only when a backend (Edge Function, Cloud Function, or your API) is implemented. Currently, **no server-side push is sent** on new messages. This is a **critical gap** for production if you want new-message notifications.

---

## 7. RATE LIMIT & SECURITY

- **Post creation:** No rate limiting in the app or in the reviewed migrations. A client could call `PostService.createPost` / `createJob` repeatedly. Recommendation: add rate limiting (e.g. Supabase Edge Function or Postgres + pg_net, or API gateway) per user/IP.
- **Messaging:** No rate limiting on `sendMessage` / `sendLocation` / `sendLiveLocation`. A client could spam messages. Recommendation: rate limit per user (and optionally per chat) on the backend.
- **Spam protection:** No throttling or cooldown in the client for post creation or sending messages. Recommendation: implement server-side (and optionally client-side) limits before scaling to 10k+ users.

---

## 8. SCALABILITY SUMMARY

| Users | Assessment |
|-------|------------|
| **50 test users** | ✅ Safe. Current design (pagination on posts/jobs, no Realtime, polling for chats/messages) is sufficient. RLS is permissive; acceptable for a closed test. |
| **10,000 users** | ⚠️ **Risky without changes.** Main issues: (1) Conversations and chat messages fetched in full (no pagination) — heavy users with many chats or long threads will hit slow queries and large payloads. (2) No RLS by user — anyone with the key can read/write all data. (3) No rate limiting — spam and abuse possible. (4) No server-side FCM — no new-message push. |
| **1,000,000+ users** | ❌ **Not supported** without significant work: (1) Paginate conversations and chat messages (cursor/offset). (2) Add `posts(created_at)` and `applications(post_id)` indexes; consider composite indexes for hot queries. (3) Enforce RLS by identity (e.g. Supabase JWT from Firebase). (4) Rate limiting and abuse controls. (5) Server-side FCM trigger. (6) Optional: Realtime for `chat_messages` scoped by `chat_id` to reduce polling. (7) Consider “load more” for Discover/Jobs. |

---

## 9. CRITICAL CHANGES (only)

1. **Database**
   - Add `CREATE INDEX IF NOT EXISTS idx_posts_created_at ON public.posts(created_at DESC);` (if `posts.created_at` exists).
   - Add `CREATE INDEX IF NOT EXISTS idx_applications_post_id ON public.applications(post_id);`

2. **Pagination**
   - **Conversations:** In `ChatServiceSupabase._fetchConversations`, add `.limit(50)` (or similar) and `.order('updated_at', ascending: false)`. Optionally support offset/cursor for “load more.”
   - **Chat messages:** In `ChatServiceSupabase.getMessages`, add a limit (e.g. last 100) and optional “load older” with cursor on `created_at` (and adjust UI to load older on scroll).

3. **RLS**
   - Harden RLS so that rows are restricted by the current user (e.g. chats where user is participant; chat_messages for those chats; users only their own row). This requires Supabase knowing the current user (e.g. custom JWT from Firebase or Supabase Auth).

4. **FCM**
   - Implement a server-side trigger (Supabase Edge Function, database webhook, or Cloud Function) that on `chat_messages` insert: resolves recipient, reads `users.fcm_tokens` and `notifications_enabled`, and sends FCM with title, body, and `data.chatId`.

5. **Rate limiting**
   - Add rate limits for post/job creation and for sending messages (per user, and optionally per chat for messages), in an Edge Function or your backend.

6. **Client**
   - Call `AppProvider.stopListeningToConversations()` when the user leaves the Messages tab (or when the app is backgrounded) so the 15s conversation polling stops when not needed.

---

## 10. WHAT NOT TO CHANGE (audit only)

- No evidence of full-table Realtime subscriptions; no change needed there until you add Realtime by design.
- Profile storage path `{user_id}/avatar.jpg` and 5MB limit are acceptable; no structural change required.
- Controllers and stream subscriptions are disposed where reviewed; no “infinite listener” bug found beyond the conversation polling lifecycle above.
- Posts/Jobs already use limit+offset in the service layer; only UI “load more” and the two new indexes are recommended for scale.

This audit reflects the **actual** structure and code; recommendations are limited to the critical items above.
