# Loading, Empty, and Offline States

This document describes the implementation of loading indicators, empty states, and offline support across the app.

---

## 1. What Was Implemented

### Shared UI components (`lib/widgets/loading_empty_offline.dart`)

- **LoadingView** – Centered spinner with optional message (e.g. "Loading posts..."). Used whenever data is being fetched and the list is empty.
- **EmptyStateView** – Icon, title, subtitle, and optional action buttons (e.g. "Refresh", "Clear Filters"). Used when there is no data and the user is online.
- **OfflineEmptyView** – Offline-specific empty state with optional retry callback. Used when the user is offline and there is no cached data to show.
- **OfflineBanner** – Subtle top bar: "You're offline — showing cached data". Shown once at app level when the device is offline.

### Connectivity (`lib/providers/connectivity_provider.dart`)

- Listens to `Connectivity().onConnectivityChanged`.
- **isOffline** is `true` when the result list is empty or every result is `ConnectivityResult.none`.
- **checkNow()** allows manual refresh (e.g. after retry).

### Caching / offline-aware loading (`lib/providers/app_provider.dart`)

- **loadPosts()** – Before calling the API, checks connectivity. If offline, returns without fetching, keeps existing `_posts`, and sets `_isLoadingPosts = false` so the UI does not show an endless spinner and cached posts remain visible.
- **loadJobs()** – Same pattern: if offline, no fetch, keep `_jobs`, set `_isLoadingJobs = false`.

No new persistence layer was added: "cache" here means the in-memory lists `_posts` and `_jobs` in `AppProvider` for the current session.

### Global offline banner

- **lib/main.dart** – `ConnectivityProvider` registered in `MultiProvider`.
- **lib/screens/home_screen.dart** – Scaffold body is a `Column`: first child shows `OfflineBanner()` when `ConnectivityProvider.isOffline`, then `Expanded` with the main content (Discover, Jobs, Messages, Profile). The banner appears at the top of the app when offline.

### Screen-by-screen behavior

| Screen      | Loading state | Empty state (online) | Empty state (offline) | Pull to refresh |
|------------|----------------|----------------------|------------------------|-----------------|
| **Discover** | `FeedSkeletonList` whenever `AppProvider.feedPresentation` is `loading` — see §4 | `EmptyStateView` ("No posts found", Refresh, Clear Filters), only from `feedPresentation == empty` | `OfflineEmptyView` with retry, only when there is nothing to render | Yes (`RefreshIndicator`) |
| **Jobs**     | `FeedSkeletonList` when `jobs.isEmpty && !hasResolvedJobs` | `EmptyStateView` ("No jobs available yet", Refresh) | `OfflineEmptyView` with retry | Yes (`RefreshIndicator`) |
| **Messages** | `LoadingView` when `isLoadingConversations && conversations.isEmpty` | `EmptyStateView` ("No messages yet", Refresh) | N/A (Firestore persistence shows cached convos when offline) | Via refresh action |
| **Profile**  | `LoadingView` when stream is waiting and no profile data yet | N/A (guest shows CTA; logged-in always has auth fallback) | N/A (Firestore persistence) | N/A |

---

## 2. Where Caching or Offline Handling Was Added

- **AppProvider** – `loadPosts()` and `loadJobs()`: connectivity check at start; when offline, skip fetch and keep in-memory lists so the UI shows last loaded data and does not show a spinner.
- **ConnectivityProvider** – Listens to system connectivity and exposes `isOffline` and `checkNow()`.
- **HomeScreen** – Renders `OfflineBanner` when `ConnectivityProvider.isOffline`.
- **Discover screen** – Uses cached posts when offline; shows `OfflineEmptyView` only when offline and no posts.
- **Jobs screen** – Uses cached jobs when offline; shows `OfflineEmptyView` only when offline and no jobs.
- **Messages / Profile** – Rely on Firestore persistence (already enabled) for offline data; no additional disk cache added in this implementation.

---

## 3. Assumptions

- **Disk cache** – Posts and jobs ARE persisted, to SharedPreferences via `CacheService`. Only the DEFAULT page is written (All tab, no search, no filters), because the cache's job is to be the first thing a cold start paints and a cold start always opens on that page. Every write goes through `AppProvider._cachePostsIfDefault` / `_cacheJobsIfDefault` so the rule holds at all five call sites. (This paragraph previously claimed in-memory only; that stopped being true when `CacheService` was added.)
- **Firestore** – Messaging and profile use Firestore with persistence enabled; their cached data is handled by the SDK when offline.
- **Connectivity** – Offline is determined at the start of `loadPosts()`/`loadJobs()` and via `ConnectivityProvider`. Requests already in flight when the device goes offline are not cancelled or specially handled in this implementation.
- **connectivity_plus** – The code uses `ConnectivityResult.none`; if your `connectivity_plus` version uses a different enum (e.g. in 6.x), adjust the condition accordingly (e.g. enum name or treat "empty list" as offline).

---

## 4. The Discover startup state machine

Discover is the first thing every user sees, signed in or not, so its startup is
a state machine rather than a pair of booleans. The four states live in
`FeedPresentation` (`lib/services/feed_snapshot.dart`) and are resolved by
`AppProvider.feedPresentation`.

| State | When | Renders |
|---|---|---|
| `loading` | No answer for the question being asked — including *"we have not asked yet"* | `FeedSkeletonList`, from the first frame |
| `content` | Any posts to render: live, stale-but-relevant, or the on-disk placeholder | The feed |
| `empty` | A **completed** load, for **this** question, returned zero rows | "No posts found" |
| `failed` | The load failed and nothing stands in for it | `ErrorRetryView` |

**The bug this replaced.** The screen used to branch on `isLoadingPosts &&
posts.isEmpty` → skeletons, then `posts.isEmpty` → the empty state. Those two
booleans cannot express the state the app is genuinely in at cold start: nothing
loaded, nothing loading, because the first ranking deliberately waits ~900 ms for
the viewer identity to resolve (`AppProvider._viewerGrace`) so it can be computed
for the right person once. "No request in flight" was read as "the request came
back empty", so every launch showed *"No posts found — try adjusting your
filters"*, then shimmer, then the feed. The same hole opened on every Requests /
Offers tab switch, where the installed page was re-filtered client-side and could
legitimately hold nothing for the new tab.

**The rules that close it:**

1. `loading` is the fallthrough, not `empty`. Absence of an answer is never
   reported as an answer.
2. `empty` requires `_hasAnswerForCurrentQuery` — a completed load whose
   `FeedIdentity.answersSameQuestionAs` the live one. Same viewer, same tab, same
   filters. A snapshot that is stale for *ranking* (the user moved, edited their
   profession) is still valid evidence about whether posts exist; a snapshot of
   another tab is not.
3. The on-disk placeholder (`FeedSnapshot.fromCache`) renders but is never
   evidence, so a warm launch shows content instantly without the cache ever
   being able to claim the marketplace is empty.
4. Posts on screen outrank everything. No refresh, re-rank, reconnect, profile
   edit or failed background rebuild may replace content with a spinner. The list
   is never assigned `[]` and never cleared ahead of its replacement.
5. Snapshot replacement crossfades (`AppProvider.feedGeneration` keys Discover's
   list; the switch is fade-only, so nothing collapses or reflows).

Pinned by `test/feed_startup_test.dart`. Its companion,
`test/feed_stability_test.dart`, pins the separate rule about what may *move*
once posts are on screen.

---

## 5. Further Improvements

- **Retry with backoff** – When a load fails (e.g. network error), show a retry action or auto-retry with exponential backoff instead of only "Refresh".
- **Sync indicator** – When back online, optionally show a short "Syncing..." or "Up to date" message after a refresh.
- **Request cancellation** – Cancel in-flight HTTP requests when the app goes offline or when the user navigates away, to avoid wasted work and state updates after dispose.
