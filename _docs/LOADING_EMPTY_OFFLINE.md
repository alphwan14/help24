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
| **Discover** | `LoadingView` when `isLoadingPosts && filteredPosts.isEmpty` | `EmptyStateView` ("No posts found", Refresh, Clear Filters) | `OfflineEmptyView` with retry | Yes (`RefreshIndicator`) |
| **Jobs**     | `LoadingView` when `isLoadingJobs && jobs.isEmpty` | `EmptyStateView` ("No jobs available yet", Refresh) | `OfflineEmptyView` with retry | Yes (`RefreshIndicator`) |
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

- **In-memory cache only** – Posts and jobs are not persisted to disk. After an app restart while offline, posts and jobs will be empty until the device is back online unless you add disk caching (e.g. local DB or secure storage).
- **Firestore** – Messaging and profile use Firestore with persistence enabled; their cached data is handled by the SDK when offline.
- **Connectivity** – Offline is determined at the start of `loadPosts()`/`loadJobs()` and via `ConnectivityProvider`. Requests already in flight when the device goes offline are not cancelled or specially handled in this implementation.
- **connectivity_plus** – The code uses `ConnectivityResult.none`; if your `connectivity_plus` version uses a different enum (e.g. in 6.x), adjust the condition accordingly (e.g. enum name or treat "empty list" as offline).

---

## 4. Further Improvements

- **Disk cache** – Persist posts and jobs (e.g. SQLite, Hive, or shared_preferences) so they survive app restarts and are available when offline with no prior in-memory load.
- **Retry with backoff** – When a load fails (e.g. network error), show a retry action or auto-retry with exponential backoff instead of only "Refresh".
- **Skeleton loaders** – Replace spinners with skeleton placeholders on Discover/Jobs for a smoother perceived loading experience.
- **Sync indicator** – When back online, optionally show a short "Syncing..." or "Up to date" message after a refresh.
- **Request cancellation** – Cancel in-flight HTTP requests when the app goes offline or when the user navigates away, to avoid wasted work and state updates after dispose.
