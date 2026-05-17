# Backend Fixes Summary

Production-oriented fixes for Firestore, messaging, profile, and notifications.

---

## 1. Firestore permissions

**File: `firestore.rules`**

- **users/{userId}**: `request.auth != null && request.auth.uid == userId` for read, write. No change in logic; comments clarified.
- **chats/{chatId}**: create only if `request.auth.uid` is in `request.resource.data.participants`; read/update/delete only if `request.auth.uid` is in `resource.data.participants`.
- **chats/{chatId}/messages/{messageId}**: read/write only if `request.auth.uid` is in the parent chat’s `participants` (via `get()`).

No permission-denied for valid logged-in users when they access only their own profile and chats they belong to.

---

## 2. User profile system

**File: `lib/services/user_profile_service.dart`**

- **ensureProfileDoc**: Wrapped in try/catch; logs and rethrows so callers can handle (e.g. permission/network).
- **updateProfile**: try/catch with log and rethrow.
- **uploadProfileImage**: Does not throw on failure. On error (Firebase not configured, size limit, Storage/network) returns `''` and logs. UI can still save name/bio.

**File: `lib/screens/edit_profile_screen.dart`**

- If upload returns empty, we keep the existing `_uploadedImageUrl` so we don’t overwrite the current photo with empty. Name and bio still save; UI updates via `Navigator.pop(true)` and auth profile update.

Profile is created when missing via existing flow in profile screen: when `watchUser` has no data and connection is done waiting, `ensureProfileDoc` is called.

---

## 3. Messaging system (unique chat per post/job)

**Bug:** All “Contact Provider” actions from Discover used the same chat (`uid1_uid2`), so all chats showed the same messages.

**Fix:** Chat id is now unique per **post** or **job** using a context id.

**File: `lib/services/chat_service_firestore.dart`**

- **chatId(user1Id, user2Id, {postId, jobId})**: If `postId` or `jobId` is set, format is `contextId_uid1_uid2` (with sorted uids). Otherwise `uid1_uid2`.
- **createChat(..., postId, jobId)**: Accepts optional `postId` and `jobId`; passes them into `chatId()` and stores `postId`/`jobId` on the chat doc when provided.

**File: `lib/providers/app_provider.dart`**

- **ensureConversationOnApply(..., postId, jobId)**: Accepts optional `postId` and `jobId` and forwards them to `ChatServiceFirestore.createChat`.

**File: `lib/screens/discover_screen.dart`**

- **_openPrivateChat**: Calls `ensureConversationOnApply(..., postId: post.id)` so each Discover post gets its own chat.

**File: `lib/screens/jobs_screen.dart`** (unchanged)

- Already passes `jobId: job.id` to `ensureConversationOnApply`.

Result:

- Each Discover “Contact Provider” creates/opens a chat with id `postId_uid1_uid2`.
- Each job application creates/opens a chat with id `jobId_uid1_uid2`.
- Messages are stored and read under `chats/{chatId}/messages/{messageId}`; no cross-chat reuse.

**sendMessage**: Validates that `senderId` is in `participants`; logs and rethrows on Firestore errors.

---

## 4. Chat initialization

- **Deterministic chatId**: `postId_uid1_uid2` or `jobId_uid1_uid2` or `uid1_uid2` (sorted). Same participants + same context always yield the same id; no reuse of old test chats when context (post/job) differs.
- **Different posts → different chats**: Discover passes `post.id`; each post has a distinct chat.
- **Different jobs → different chats**: Jobs screen passes `job.id`; each job has a distinct chat.

---

## 5. Notifications (FCM)

**File: `lib/services/notification_service.dart`**

- **initialize()**: Already in try/catch; added stack trace log in debug. Does not throw.
- **setupMessageHandlers()**: Wrapped in try/catch. `onMessage` and `onMessageOpenedApp` listeners have `onError` handlers. `getInitialMessage().then(...).catchError(...)` so unhandled promise errors don’t crash the app.

App does not crash if FCM fails (e.g. web without service worker, or permission denied). For “mock when local”: FCM simply doesn’t initialize or deliver messages when it fails; no separate mock implementation added.

---

## 6. Data consistency

- No dummy/test/static message or chat data in code. Conversations and messages come from Firestore only.
- `lib/utils/guest_id.dart` only states that sign-in is required (no fake users).
- Diagnostic test upload in `main.dart` runs only in `kDebugMode`; not user-facing data.

---

## 7. Error handling

- **ChatServiceFirestore**: `sendMessage` logs invalid chatId, non-participant sender, and Firestore errors; rethrows so UI can show a message.
- **UserProfileService**: `getUser` logs and returns null; `ensureProfileDoc` and `updateProfile` log and rethrow; `uploadProfileImage` logs and returns `''`.
- **NotificationService**: All entry points catch and log; no silent failures.

---

## Files changed

| Area        | File |
|------------|------|
| Rules      | `firestore.rules` |
| Chat       | `lib/services/chat_service_firestore.dart` |
| App state  | `lib/providers/app_provider.dart` |
| Discover   | `lib/screens/discover_screen.dart` |
| Profile    | `lib/services/user_profile_service.dart`, `lib/screens/edit_profile_screen.dart` |
| FCM        | `lib/services/notification_service.dart` |

---

## Optional follow-ups

- **Firebase Storage rules**: If profile uploads are restricted, add Storage rules for `profiles/{uid}.*` so authenticated users can read/write their own file.
- **firebase-messaging-sw.js (web)**: For web FCM, ensure the service worker is placed and served with MIME type `application/javascript`; the app no longer crashes if FCM fails.
- **Conversation from notification**: `main.dart` builds a minimal `Conversation(id: chatId, ...)` when opening from a notification; `participantId` is left default. If the Messages list needs to show the correct name/avatar, the app could fetch the chat doc or participant profile by `chatId` when opening from a notification.
