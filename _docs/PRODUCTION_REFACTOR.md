# Production Refactor Summary

This document summarizes the production-quality changes applied across Firestore/messaging, cards, filters, and owner controls.

---

## 1. Firestore Data & Messaging

### Chat ID and job-scoped threads
- **`lib/services/chat_service_firestore.dart`**
  - **`chatId(user1Id, user2Id, {String? jobId})`**  
    With `jobId`: format `jobId_uid1_uid2` (one chat per job). Without: `uid1_uid2` (sorted).
  - **`participantsFromChatId(chatId)`**  
    Supports both formats (2 or 3 segments).
  - **`jobIdFromChatId(chatId)`**  
    Returns `jobId` when present.
  - **`createChat(..., jobId: jobId)`**  
    Stores `jobId` on the chat doc when provided; uses job-scoped `chatId` so each job has its own thread.

### Contact Provider from Jobs
- **`lib/providers/app_provider.dart`**  
  **`ensureConversationOnApply(..., jobId: jobId)`**  
  Accepts optional `jobId` and passes it to `ChatServiceFirestore.createChat`.
- **`lib/screens/jobs_screen.dart`**  
  When submitting an application, calls `ensureConversationOnApply(..., jobId: job.id)` so the conversation is created with a job-specific chat ID.

Result: no cross-post message leakage; each job has its own chat. Discover (posts) continues to use user-only `chatId` (no `jobId`).

### Data source
- No dummy or test data in UI; posts, jobs, and conversations come from Supabase/Firestore. Messages are scoped by `chats/{chatId}/messages`.

---

## 2. Profile System (verified)

- **Profile photo:** `UserProfileService.uploadProfileImage` → Firebase Storage `profiles/{uid}` → profile doc updated (see `edit_profile_screen.dart`).
- **Profile changes:** `StreamBuilder` on `UserProfileService.watchUser(uid)` so name, bio, language, and notifications reflect immediately.
- **FCM:** `NotificationService` handles token and tap; `main.dart` navigates to chat/post from notification payload.
- **Language:** `LocaleProvider` loads/saves language in Firestore `users/{uid}.language` (English/Swahili).
- **Terms of Service / Privacy Policy:** Profile screen opens WebView for `AppUrls.termsOfService` and `AppUrls.privacyPolicy` (hosted URLs in `app_urls.dart`).

---

## 3. Job & Post Cards (Discover + Jobs)

### JobCard (Jobs tab) — rebuilt
- **Layout (aligned with PostCard):**
  - Top row: category label (left), timestamp (right).
  - Title (bold, 2 lines max).
  - **Difficulty & urgency:** Small tags under title from `job.difficulty` and `job.urgency` (e.g. [Medium] [Urgent]); if difficulty is Any, job type is shown.
  - User row: avatar, name, **rating** (⭐ 4.7 (23) or “New”), location with **`Icons.location_on_outlined`** (no emoji).
  - Description preview (2–3 lines).
  - Media: small thumbnail or “X photos” indicator.
  - Bottom: price (left), Apply / Application Sent (right).
- **JobModel** (`lib/models/post_model.dart`): added `rating`, `authorReviewCount`, `difficulty`, `urgency`, `categoryName`; getters `urgencyText`, `urgencyColor`, `difficultyText`; parsing in `fromJson` from API (e.g. `author_review_count`, `difficulty`, `urgency`, `category`).

### PostCard (Discover)
- **Difficulty & urgency:** Small tags under title (same style as JobCard): `_SmallTag` with `post.difficultyText` / `post.urgencyText`.
- Existing: category badge, timestamp, title, user row (name + rating, location with `Icons.location_on_outlined`), description, media, price, View/Respond.

### Location icon
- **`lib/widgets/marketplace_card_components.dart`**  
  **LocationChip:** emoji replaced with **`Icons.location_on_outlined`** for a consistent, professional icon.

### Owner controls
- **Jobs:** Job detail sheet shows **Delete** and **Mark as Completed** for the author.  
  - **Mark as Completed:** `AppProvider.markJobCompleted(jobId, currentUserId)` → `PostService.updatePost(id, {'status': 'completed'})`, then job removed from local list.  
  - **Note:** Backend `posts` table should have a nullable `status` column for “completed” to persist; otherwise the update may fail until the column is added.
- **Discover:** Post detail sheet already has **Delete** for the author (unchanged).

---

## 4. Filters

- **Jobs use same filter set as Discover:**  
  **`lib/providers/app_provider.dart`** — `loadJobs()` builds the same `PostFilters` (search, categories, city, area, urgency, price range, difficulty) and passes them to **`PostService.fetchJobs(filters)`**.
- **`lib/services/post_service.dart`** — **`fetchJobs`** applies: city, area, categories, urgency, difficulty, min/max price, search (title/description). Order: `created_at` desc.

Filters are aligned with Firestore/Supabase fields and apply to both Discover (posts) and Jobs.

---

## 5. UI & State

- **Conversations:** Still driven by `ChatServiceFirestore.watchConversations(currentUserId)`; list updates in real time; offline: Firestore persistence shows cached chats.
- **Cards:** JobCard and PostCard share the same layout language (category, timestamp, title, tags, user row with rating and location icon, description, media, price, CTA).
- **Messaging:** Each job gets its own chat via `jobId` in `chatId`; opening “Contact Provider” from a job creates/opens that job’s chat only.

---

## 6. What was not implemented

- **Location-based feed:** Sort by “same location first”, then rating, then newest would require device location, a location field on posts/jobs, and ordering (e.g. in API or client). Not done in this refactor.
- **Hiding completed jobs from feed:** Filtering out `status == 'completed'` in `fetchJobs` was not added so that deployments without a `status` column are not broken. To enable: add nullable `status` to `posts`, then in `PostService.fetchJobs` add e.g. `.or('status.is.null,status.neq.completed')` (syntax may vary by Supabase/PostgREST version).
- **Rating/min rating filter for jobs:** `PostFilters` has no `minRating` applied in `fetchJobs`; posts use it via client-side filtering. Jobs could be extended the same way if the API exposes rating.

---

## File change list

| Area        | Files |
|------------|--------|
| Chat/JobId | `lib/services/chat_service_firestore.dart`, `lib/providers/app_provider.dart`, `lib/screens/jobs_screen.dart` |
| Job model  | `lib/models/post_model.dart` (JobModel: rating, authorReviewCount, difficulty, urgency, categoryName, getters) |
| JobCard    | `lib/widgets/job_card.dart` (full layout rebuild) |
| PostCard   | `lib/widgets/post_card.dart` (difficulty/urgency chips) |
| Location   | `lib/widgets/marketplace_card_components.dart` (LocationChip icon) |
| Filters    | `lib/providers/app_provider.dart` (loadJobs with filters), `lib/services/post_service.dart` (fetchJobs filters) |
| Owner      | `lib/providers/app_provider.dart` (markJobCompleted), `lib/screens/jobs_screen.dart` (Mark completed + Delete) |
