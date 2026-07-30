# Production UX Stability Audit

**Scope:** feed installation lifecycle, recommendation synchronisation, own-post
optimistic updates, notification state management, unread-count lifecycle,
offline persistence, notification centre information architecture.

**Non-scope:** the ranking algorithm. Scoring, weights and signals are correct
and are not touched anywhere in this work. Everything below is about *when* a
ranking is allowed to reach the screen and *how* its updates are presented.

---

## 0. Executive summary

Help24 already has a stability *contract* — `FeedSnapshot`, `FeedArrival`,
`FeedPresentation`, `FeedInvalidation` — and it is well designed. The bugs are
not failures of that contract. They are three things the contract does not yet
cover:

1. **Startup is not a transaction.** Four independent code paths may each
   install a feed during the first two seconds. Each install bumps
   `_feedGeneration`, which re-keys Discover's list. That re-key *is* the blink.
2. **The optimistic insert edits the working list but not the ranking of
   record.** So the author's own post is invisible to every subsequent
   comparison, and the very next rebuild counts it as somebody else's new post.
3. **Notifications have no store.** The screen and the badge are two independent
   widgets, each with its own fetch, its own realtime channel and its own idea
   of the truth, with no cache, no sequencing and no offline path.

Everything reported by the user follows from those three.

---

## Part 1 — Root causes

### 1.1 Feed blinks and re-installs after Discover is already visible

**There is no splash gate.** `main.dart:595` hands `StartupGate` straight to
`HomeScreen`, and `StartupGate.build` (`main.dart:627`) is
`=> const HomeScreen()`. The Android native splash (`launch_background.xml`,
`splash_background = #0A0A0A`) disappears at the *first Flutter frame*, which is
Discover with skeletons. So every subsequent arrival is seen by the user.

**Four paths can install a feed, and up to four of them run per launch:**

| # | Path | File |
|---|------|------|
| 1 | disk cache placeholder | `app_provider.dart:651` `_hydrateFromCache` |
| 2 | chronological placeholder after 1200 ms | `app_provider.dart:519` `_paintEarlyPageIfRankingIsSlow` |
| 3 | the launch ranking | `app_provider.dart:430` `_openWithLaunchRanking` |
| 4 | `setViewer` from HomeScreen's post-frame callback | `app_provider.dart:1840` ← `home_screen.dart:311` |

`_install` (`app_provider.dart:994`) bumps `_feedGeneration` every time, and
Discover keys its list on it (`discover_screen.dart:680`). A generation bump
means: new `KeyedSubtree` → `AnimatedSwitcher` crossfade → the `ListView` is
rebuilt from scratch → scroll position resets. **Two installs = one visible
blink. Three = two.**

**Path 4 is the one that lands last and hurts most.** `StartupPrefetch` ranks
against `LocationProvider.lastKnownCoordinates(uid)` — the *stored* position.
`HomeScreen._handleAuthLocationFlow` then calls `location.initializeForUser(uid)`
and passes whatever comes back to `setViewer`. `StartupPrefetch.answers()`
(`startup_prefetch.dart:175`) compares raw doubles for equality. Any position
refresh at all — a fresh fix, a permission that just resolved, a rounding
difference — makes `answers()` false, and `setViewer` issues
`loadPosts(reason: explicit)`. `explicit` is in `replacesVisibleFeed`, so it
lands **unconditionally, on a reader, a second into the session.**

The same call also covers the "gained coordinates" case: prefetch ranked with no
position, HomeScreen supplies one → `FeedInvalidation.location` +
`gainsCoordinates` → `FeedArrival.installs` returns true → replaces the visible
feed.

**Path 2 is a guaranteed second install on a cold backend.** It exists to avoid
eight seconds of shimmer, and that is a real problem — but its cure is a
placeholder that the ranked page then replaces in front of the user.

**Secondary churn:** `loadUrgentPosts` runs twice at startup
(`app_provider.dart:407` and `discover_screen.dart:79`), each with two
`notifyListeners()`. `_warmOtherScopes` (`app_provider.dart:564`) issues two more
sequential feed requests during launch. Total first-launch network calls: ~8.

### 1.2 "New posts available" for the user's own post

`createPost` (`app_provider.dart:1198-1213`):

```dart
_posts.insert(0, createdPost);        // working list only
...
unawaited(loadPosts(reason: FeedInvalidation.authored));
```

`_installed` — the *ranking of record* — is never updated. The consequences
compound:

1. `loadPosts(authored)` returns a server page that **does** contain the new
   post. `_shouldInstall` → `FeedArrival.installs`: `authored` is deliberately
   not in `replacesVisibleFeed` (`feed_snapshot.dart:385`), so it falls through
   to `return !differsVisibly`.
2. `differsVisiblyFrom` compares the new page against the **stale** `_installed`
   (which lacks the authored post). The head almost always differs. →
   `_pending = snapshot`.
3. `pendingFeedNewPostCount` (`app_provider.dart:293`) then does
   `next.newPostCountSince(_installed)` — again against the stale snapshot — so
   **the author's own post is counted as a new post**.
4. `discover_screen.dart:579` prefers the specific copy, so the pill reads
   **"1 new post"** rather than the generic line.

So the app tells the author about the post they just wrote. The comment at
`app_provider.dart:1211` shows the *intent* was right ("Offered, not applied");
the mechanism just has no way to know the offer contains only the author's own
work.

There is also no rule anywhere that says *who* a pending post belongs to. Even
for genuine third-party posts, the banner currently fires on any visible head
difference — including a pure re-ranking with zero new listings, in which case
the copy falls back to "New recommendations" but the trigger was never about
recommendations entering a window.

### 1.3 Unread badge oscillation

`_NotificationBadgeState` (`notifications_screen.dart:731`) has five independent
defects, and they compose exactly into the reported `(2) → gone → (2) → (1)`:

| Defect | Line | Effect |
|---|---|---|
| `int _unread = 0` initial, no persistence | 733 | every cold start renders **no badge**, then pops one in when the network answers |
| `PostgresChangeEvent.all` | 763 | every INSERT **and every UPDATE** triggers a full re-count |
| `_refresh()` has no sequence guard | 781 | concurrent COUNT queries land out of order; an older answer overwrites a newer one |
| no debounce / coalescing | 771 | `markAllRead` (one statement, N rows) emits N realtime events → N queries |
| errors are swallowed silently | 786 | a failed count leaves the previous value with no signal that it is stale |

`markAllRead` is the clearest reproduction: mark 5 read → 5 UPDATE events → 5
un-sequenced COUNT queries racing → the badge steps through arbitrary values
before settling.

**And there is no shared source of truth.** `NotificationsScreen` computes
`unread` from its own in-memory list (`notifications_screen.dart:470`, capped at
50 rows); `NotificationBadge` computes it from a separate DB query over all
rows. The two can legitimately disagree, and neither informs the other — the
badge only learns that the screen marked something read via a realtime round
trip.

### 1.4 Offline notifications: appear → disappear → infinite spinner

`_load()` (`notifications_screen.dart:167`):

```dart
setState(() { _loading = true; _error = null; });   // ← unconditional
```

and `_buildBody` returns a full-screen `CircularProgressIndicator` whenever
`_loading` (line 516). `_load` is wired to **three** triggers: `initState`,
`RefreshIndicator.onRefresh` (564) and `ReconnectListener.onReconnect` (499).

So: notifications are on screen → connectivity flaps → `ReconnectListener` fires
→ the list is *replaced* by a spinner → `NotificationsDb.fetchForUser` (55) has
**no timeout**, so with no usable network the PostgREST request hangs → the
spinner never resolves. That is the reported sequence, precisely.

**There is no notification cache of any kind.** `CacheService` covers posts,
jobs, conversations, message bodies and the outbox — notifications were never
added. Offline, the screen has literally nothing to render, so a failed refresh
is indistinguishable from an empty inbox.

The realtime INSERT handler (138) also prepends without deduplicating against
`_load` results, so a push that arrives during a refresh can render twice.

### 1.5 Notification centre is a flat list

- One chronological `ListView.separated` (566). No sections, no grouping, no
  priority, no pagination (`limit: 50`, hard).
- The tile shows title, body, relative time. It does not show **who** initiated
  the event or **which** post/job it belongs to — that context sits unused in
  `n.data`.
- No contextual actions. Every notification has exactly one interaction: tap the
  whole row.
- **Seven backend notification types are dead on tap.** The backend emits 23
  types; `_navigateFromNotification` (232) handles 16. `review_received`,
  `job_cancelled`, `payout`, `promotion_payment_received`, `promotion_live`,
  `promotion_rejected` and `promotion_completed` hit `default:` → a `debugPrint`
  and nothing else. They also fall through `_icon`/`_iconColor` to the generic
  grey bell.
- `_openChatById` (348) selects `profile_picture_url`, a column that does not
  exist on `users` — `main.dart:294` uses `avatar_url` with a `profile_image`
  fallback. The query throws, is swallowed, and the chat header shows a generic
  name.

---

## Part 2 — Architectural weaknesses

**W1 — Startup has no owner.** Four paths race to install a feed and each is
individually reasonable. Nobody arbitrates. There is no single object that can
answer "is the launch feed final yet?"

**W2 — `_install` conflates *replace* with *edit*.** It is documented as the
only place `_posts` is wholesale replaced, and it bumps the generation. But
there is no counterpart for "same ranking, edited contents" — so local splices
(`createPost`, `deletePost`, `markApplied`) mutate `_posts` behind
`_installed`'s back and desynchronise the ranking of record. Every downstream
comparison then reasons about a feed that is not on screen.

**W3 — The pending-feed offer has no notion of authorship or relevance.** It
fires on head difference alone. "Genuinely relevant posts entered my
recommendation window" is not currently expressible.

**W4 — Notifications have no service layer.** Two widgets each own a fetch, a
realtime subscription and a copy of the state. Every stability rule the feed
learned (sequence guards, cache-first hydration, "a failed fetch is never
published as an empty result", offline is not emptiness) had to be written in
`AppProvider` and was never carried across.

**W5 — Realtime is used as a change *trigger* rather than a change *payload*.**
The badge throws away the row it was handed and re-queries the whole count. The
payload already says what changed.

**W6 — Notification taxonomy lives in three places and agrees in none.** The
backend's 23 emitted types, the tile's `switch` (14), and the router's `switch`
(16) are maintained independently. A new backend type silently degrades to a
grey bell that does nothing when tapped.

---

## Part 3 — Proposed architecture

### 3.1 `LaunchSequence` — startup as one transaction

A new service that owns the launch and answers one question: *may the app show
Discover yet?*

- `main.dart` renders a Flutter splash **pixel-identical to the native one**
  (`#0A0A0A` + centred badge), so the native → Flutter handoff is invisible.
- The splash is held until `LaunchSequence.ready` completes:
  viewer identity resolved **and** the first ranked snapshot installed.
- Hard deadline (**2200 ms**). On expiry the app proceeds with whatever it has
  — disk cache, chronological page, or skeletons. A cold backend costs a beat,
  never a hang.
- While the gate is held, installs are free: nothing is on screen to disturb.
  `_paintEarlyPageIfRankingIsSlow` becomes *pre-splash-lift* work rather than a
  visible swap.
- **After the gate lifts, the launch paths are closed.** `_openWithLaunchRanking`
  and the disk hydrate can no longer install; they may only `_offer`.

The rule this creates: **at most one install happens before Discover is
visible, and none of them is visible.**

### 3.2 `_install` vs `_splice` — atomic replacement, non-atomic edit

Split the one operation into two with different generation semantics:

```
_install(snapshot)   → replaces the ranking. Bumps _feedGeneration. Crossfade.
_splice(mutator)     → edits posts within the installed ranking.
                       Updates BOTH _posts and _installed (via withPosts).
                       Does NOT bump the generation. No crossfade, no scroll loss.
```

`createPost`, `createJob`, `deletePost` and `addPost` all move to `_splice`. The
ranking of record then always describes what is on screen, which makes every
downstream comparison correct by construction.

### 3.3 Own posts are silent, by identity not by heuristic

Three changes, layered:

1. **The insert is a splice** (3.2), so `_installed` contains the authored post
   immediately.
2. `pendingFeedNewPostCount` becomes `newPostCountSince(current, excludingAuthor: _viewerUserId)`
   — the viewer's own listings are structurally excluded from the count.
3. `_shouldInstall` gains a pre-check: **a pending snapshot whose only novelty is
   the viewer's own authored posts is absorbed silently, not offered.** If the
   reader is at the top it is installed (it moves nothing they did not cause);
   if they are scrolled, it is held without a banner and applied on the next
   natural boundary.

Result: publish a post → it appears at the top of your feed, instantly, with no
banner, no animation, no interruption. Exactly as specified.

### 3.4 The banner becomes a recommendation offer

Rename the concept and tighten the trigger. The pill appears only when **all**
of the following hold:

| Condition | Mechanism |
|---|---|
| Discover is the visible tab | `_discoverVisible` (already exists) |
| the reader is not at the top | `_readerEngaged` (already exists) |
| the new posts are not the viewer's own | §3.3 |
| genuinely new listings entered the ranked window | `newPostCountSince > 0` **and** at least one of them is inside the visible head |
| the engine ranked them (not the chronological fallback) | `snapshot.isRanked` |

Copy becomes **"New recommendations available"** in all cases — never "N new
posts". Help24 recommends; it does not enumerate. (The count survives internally
for telemetry.)

### 3.5 `NotificationStore` — one owner for notification state

A `ChangeNotifier`, registered with `SessionScope`, that is the single source of
truth for the list **and** the unread count. Modelled directly on the contracts
the feed and Messages already prove out:

| Contract | How |
|---|---|
| **cache-first** | hydrate from `CacheService.loadNotifications(uid)` before any network call; the screen never opens on a spinner if history exists |
| **a failed fetch is never published as an empty result** | errors set an error slot; they never clear the list |
| **offline is not emptiness** | connectivity is checked before fetching; offline keeps cached rows fully readable and scrollable |
| **sequence-guarded** | monotonic request ids; a stale response cannot overwrite a fresh one |
| **coalesced realtime** | one subscription for the whole app; INSERT applies the payload row directly (no re-query); UPDATE adjusts the count from the delta; a 250 ms coalescing window absorbs `markAllRead` bursts |
| **optimistic reads** | tapping marks read locally and immediately; the DB write is fire-and-forget with rollback on failure |
| **session-scoped** | keyed by uid, purged by `SessionScope` like conversations and message bodies |
| **timeout** | every query bounded at 8 s, matching `FeedService` |

The badge and the screen both become thin `Consumer`s of this store. They
cannot disagree, because there is only one number.

**Unread count lifecycle** — the count changes on exactly four events, and
nothing else: a new notification arrives (+1), a notification is read (−1), all
are read (→0), a completed refresh reports an authoritative count. It never
resets to 0 on a failed load, never re-queries on an unrelated realtime event,
and is persisted so a cold start renders the last known count on the first
frame.

### 3.6 Notification taxonomy — one definition

A `NotificationKind` model, single file, that maps each backend type to:

```
category  →  Applications | Jobs | Payments | Disputes | Reviews
             | Provider | Messages | Promotions | System | Support
priority  →  critical | high | normal | low
icon, colour, title template, action label, deep-link route
```

Everything derives from this: sectioning, ordering, the icon, the tile's action
button and the router. A backend type with no entry falls back to a defined
`unknown` kind that still renders sensibly and still routes to a safe
destination — it can no longer be dead on tap. The seven currently-dead types
get real entries and real routes.

**Priority model** (§7 of the request):

| Priority | Kinds | Behaviour |
|---|---|---|
| `critical` | dispute opened / evidence requested / resolution, payment secured, payout released, refund processed | pinned above the timeline while unread |
| `high` | selected for job, new application, completion requested, review requested | timeline, emphasised |
| `normal` | new message, offer/counter-offer, review received, promotion live | timeline |
| `low` | profile updated, badge earned, promotion completed, system/maintenance | timeline, de-emphasised |

Ordering is `(pinned critical unread) → (time desc)`. Priority never reorders
*read* items — a resolved dispute from last week does not outrank this
morning's application. That keeps the list honest and stable.

### 3.7 Notification centre redesign

Airbnb/Stripe register, not a social feed:

- **Sections**: an unread "Needs your attention" block (critical + high, unread
  only) followed by date-grouped history (Today / Yesterday / This week /
  Earlier).
- **Tile** answers all five required questions: what happened (title), who
  initiated it (actor name + avatar, from `data`), which post/job it belongs to
  (subject line), when (relative time), what to do (a single contextual action
  button, only when there is a real next step).
- **Grouping**: consecutive same-kind, same-subject notifications collapse into
  one expandable row ("3 new applications on *Fix kitchen sink*").
- **Category filter chips** across the top, driven by `NotificationKind.category`.
- Pagination (30/page, infinite scroll) replacing the hard 50 cap.
- Restrained: one accent per category, no gradients, no motion beyond a 200 ms
  fade on read-state change.

---

## Part 4 — Rollout plan

| Phase | Deliverable | Risk | Independently shippable |
|---|---|---|---|
| **1** | `_splice` / `_install` split; `createPost`/`createJob`/`deletePost` move to it | low | yes |
| **2** | Own-post silence + "New recommendations available" trigger and copy | low | yes |
| **3** | `LaunchSequence` + Flutter splash gate; launch paths closed after lift | **medium** | yes |
| **4** | `NotificationStore` + `CacheService` notification cache + offline path | medium | yes |
| **5** | Badge and screen rewired onto the store; badge oscillation gone | low | needs 4 |
| **6** | `NotificationKind` taxonomy + priority + router completion | low | yes |
| **7** | Notification centre redesign (sections, grouping, actions, pagination) | low | needs 4+6 |
| **8** | Regression tests across all of the above | — | — |

Phases 1–2 are pure provider changes with existing test coverage nearby
(`feed_stability_test.dart`, `feed_arrival_test.dart`,
`post_creation_state_test.dart`). Phase 3 is the only one that changes perceived
launch behaviour and is therefore the one to watch. Phases 4–7 are additive:
until the screen is rewired, the store is dead code.

---

## Part 5 — Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | **Splash gate makes launch feel slower.** Holding for a ranked page trades blink for latency. | Hard 2200 ms deadline; the gate also lifts the instant the feed is final, so a warm launch is *faster* to useful content than today (no skeleton stage). Deadline is one constant, trivially tunable. |
| R2 | **Splash gate hangs on a dead backend.** | The deadline is a `Future.any` race, not a dependency. Every await inside `LaunchSequence` is already failure-safe (`StartupPrefetch._guard` returns null on any error). Worst case = today's behaviour. |
| R3 | **`_splice` desynchronises `_installed` from `_posts`.** | `_splice` is the only mutator; `_posts` becomes a derived value written from the snapshot on every call. Enforced by a test asserting `_posts == _installed.posts` after every mutation. |
| R4 | **Own-post suppression hides genuine third-party posts** if authorship is misread. | Suppression keys off `authorUserId == _viewerUserId`, an exact id match on a server-supplied field. When the viewer is null (signed out) suppression is disabled entirely — an anonymous browser has no own posts. |
| R5 | **`NotificationStore` cache leaks across accounts.** | Keyed with `SessionScope.scopedKey`, registered as `SessionScoped`, prefix added to `uidScopedPrefixes` — the same three defences that fixed the conversations leak. |
| R6 | **Optimistic mark-read diverges from the DB** if the write fails. | Rollback on failure + reconciliation against the authoritative count on the next completed refresh. |
| R7 | **Notification pagination + realtime insert conflict** (a pushed row also arriving in page 2). | Dedup by id on every merge; the store holds an id-keyed map, not a list. |
| R8 | **Priority pinning makes the list feel unstable** if it re-sorts under the reader. | Pinning applies only to *unread* critical items, is computed once per load, and never re-sorts in response to a background refresh — the same frozen-snapshot discipline the feed uses. |

---

## Part 6 — Migration strategy

**No database migration is required.** Every schema element already exists:
`notifications(id, user_id, type, title, body, data, read, created_at)` from
migration 033, realtime publication from 040, RLS from 080. The taxonomy,
priority and grouping are all client-side derivations of `type` and `data`.

**Client-side migrations:**

1. **Notification cache key** — new (`help24_cache_notifications_<uid>`).
   No prior version exists, so a first run is a cache miss, which is already the
   handled path. Added to `SessionScope.uidScopedPrefixes` in the same change so
   it can never outlive its session.
2. **`FeedIdentity.feedVersion`** stays at 1. Nothing about what ranking *means*
   changes, so cached snapshots from the current build remain valid — bumping it
   would force an unnecessary cold rebuild on every device at update time.
3. **`NotificationBadge`'s public API is preserved** (`userId` + `child`), so the
   single call site in `discover_screen.dart:267` needs no change and the widget
   can be swapped underneath.
4. **Backward compatibility with unknown types** is a first-class case, not an
   afterthought: the `unknown` kind is what makes it safe to ship the client
   ahead of any future backend notification type.

---

## Part 7 — Regression strategy

**Existing tests that must stay green** (they encode the contracts this work
extends, not replaces): `feed_stability_test.dart`, `feed_startup_test.dart`,
`feed_arrival_test.dart`, `post_creation_state_test.dart`,
`offline_conversations_test.dart`, `session_isolation_test.dart`,
`silent_failure_test.dart`, `connectivity_provider_test.dart`.

**New tests, one per rule this audit establishes:**

*Feed*
- a launch installs **exactly one** snapshot before the splash lifts
  (`_feedGeneration == 1` at gate lift)
- the splash gate lifts within the deadline when the backend never answers
- `setViewer` with coordinates within `significantMoveKm` after a launch ranking
  issues **no** request and installs **nothing**
- `_splice` preserves `_feedGeneration` and keeps `_posts == _installed.posts`

*Own post*
- `createPost` produces `hasPendingFeed == false`
- `pendingFeedNewPostCount` excludes the viewer's own authored posts
- a third-party post while scrolled **does** produce a pending offer
- the pill copy is "New recommendations available" and never "N new posts"

*Notifications*
- unread count is monotonic through `markAllRead` (never oscillates); asserted by
  recording every emitted value
- an out-of-order count response cannot overwrite a newer one
- a failed refresh leaves cached notifications on screen and does not clear the
  count
- offline open renders cached history, scrolls, and never enters a loading state
  that does not terminate
- an unknown notification type renders and routes to a safe destination
- realtime INSERT during an in-flight load produces no duplicate row
- priority ordering pins unread critical items and does not re-sort read ones

*Session*
- the notification cache is purged on sign-out and unreadable by the next account

---

## Part 8 — As built

Every phase in Part 4 is implemented. `flutter analyze` is clean and the suite is
**642 tests, all passing** (was 566 — 76 added).

### New files

| File | What it owns |
|---|---|
| `lib/services/launch_sequence.dart` | The launch latch and its deadline |
| `lib/widgets/launch_splash.dart` | The Flutter half of the launch screen |
| `lib/models/app_notification.dart` | The notification model + `NotificationKind` taxonomy |
| `lib/services/notification_store.dart` | The single owner of notification state |
| `lib/utils/notification_sections.dart` | Grouping, date buckets, sectioning (pure) |
| `assets/splash_badge.png` | Copy of the xxxhdpi Android drawable, for a pixel-exact handoff |

### Key changes

**Feed**
- `_install` / `_splice` split in `AppProvider`. `_splice` writes **both**
  `_posts` and `_installed` and leaves `_feedGeneration` alone; `createPost`,
  `createJob`, `deletePost`, `addPost` and `addApplicationToPost` all use it.
- `FeedArrival.installs` gained `launchInProgress` as rule 2 — during the splash
  every arrival lands, because nothing is on screen to disturb.
- `_worthOffering` is the new gate on the banner: engine-ranked, genuinely new,
  and not the reader's own. A pure re-ranking is offered only when it would
  replace a *placeholder* — which is what stops a cold ranker that overran the
  deadline from being silently discarded.
- `newPostCountSince` takes `excludingAuthor`.
- The pill's copy is now fixed at **"New recommendations available"**.
- `AppProvider.notifyListeners` is a no-op after `dispose` — a real hazard on
  hot restart and on a sign-out racing the launch loads.
- `loadUrgentPosts` is sequence-guarded and freshness-gated (20 s), which turns
  the second of the two launch-time calls into a re-sort rather than a fetch.
  `force: true` on every path where the user actually asked.
- Discover's urgent pill and recommendations pill are `Selector`s, not
  `Consumer`s — they no longer rebuild on every search keystroke.

**Notifications**
- `NotificationStore`: cache-first, sequence-guarded, coalesced realtime,
  offline-readable, session-scoped, 8 s timeouts, paginated (30/page).
- Realtime payloads are used as **data**: an insert is a row, an update is a
  known read-state delta. Neither triggers a query. Only rows outside the loaded
  pages schedule a coalesced (600 ms) reconcile.
- The badge and the screen are now thin views. `NotificationBadge`'s public API
  is unchanged, so its call site did not move.
- `CacheService.saveNotifications` / `loadNotifications` store the rows **and**
  the authoritative unread count, so a cold start renders the right badge on its
  first frame instead of 0.
- Every one of the backend's 22 canonical types is mapped, prioritised, iconed
  and routed. The seven that were previously dead on tap now go somewhere.
- Fixed: `_openChatById` selected `profile_picture_url`, which does not exist —
  now `avatar_url` with a `profile_image` fallback, matching the rest of the app.

### Deliberate deviations from the plan

- **The taxonomy forward-declares eleven types the backend does not yet emit**
  (`application_withdrawn`, `verification_approved`, `badge_earned`,
  `profile_updated`, `security_alert`, `maintenance`, `version_update`,
  `support_reply`, `support_ticket_updated` …). They are the ones named in the
  brief. They cost nothing, they are marked as such, and they mean the client is
  ready before the backend is. The `unknown` fallback covers everything else.
- **`main.dart`'s FCM router was left alone.** It routes `RemoteMessage`
  payloads from a different context (no store, possibly no widget tree) and is
  working. Unifying it with `NotificationKind` is a worthwhile follow-up, not a
  prerequisite — the screen's router, which is where the dead types were, is
  now total.
- **Actor names and post titles are not resolved.** The tile answers *what /
  which / when / what next* from the payload, and *who* from the server-written
  body (which already reads "Alice applied to …"). A batched lookup against
  `public_profiles` and `posts` would upgrade the subject line and make grouping
  headlines name the job. It is one query per page and genuinely nice, but it is
  new network work on a screen whose whole problem was unreliable network work,
  so it belongs in its own change.

---

## Part 9 — Round two: the splash blinked and the feed still moved

The first pass fixed the four *provider-level* installers but left three defects
that produce the same symptoms from the presentation layer. All are fixed.

### 9.1 The splash blinked — the badge decoded asynchronously

`AssetImage` resolves asynchronously, so the first Flutter frame painted the
brand field with **nothing on it** and the badge appeared a frame or two later —
landing immediately after the Android splash had faded its own icon out. Two
logos vanishing and reappearing within a few frames is the blink.

`LaunchSplash.warm()` now decodes the badge before `runApp`, awaited while the
native splash is still up, bounded at 500 ms. `gaplessPlayback` keeps it painted
across rebuilds.

### 9.2 The splash blinked — the whole app rebuilt underneath it

`Consumer2<AppProvider, LocaleProvider>` wrapped the **entire `MaterialApp`**,
and `AppProvider` notifies on every keystroke, filter change, load transition
and feed install. So the app tree rebuilt dozens of times during one launch, and
each rebuild re-issued `SystemChrome.setSystemUIOverlayStyle` — which fought the
splash's own `AnnotatedRegion` for the system bars.

Now a `Selector<AppProvider, ThemePreference>`: only the theme choice can change
anything there. `LocaleProvider` was watched for nothing —
`AppLocalizationsLoader` watches it itself. The overlay call is suppressed while
the splash owns the bars and re-applied once by `StartupGate` at handover.

### 9.3 The feed still moved — sponsored slots are rows, not an overlay

**The one that mattered.** `FeedComposer` *inserts* sponsored cards between
organic ones, and Discover fetched them from its post-frame callback — so the
response landed a beat after the feed was visible and pushed every card below
the first slot down the screen. Indistinguishable from a re-ranking, and it
happened on every launch. This was a second feed installation hiding in plain
sight, and the first pass did not touch it.

Three changes:

- **The shell is now built *behind* the splash** rather than after it.
  `StartupGate` renders `HomeScreen` underneath an opaque `LaunchSplash` and
  fades the splash out, so Discover's `initState` and post-frame work — viewer
  identity, urgent list, sponsored slots — all get the same free window every
  other launch path gets. What is revealed is composed and finished.
- **Late slots are held.** A slot response arriving while the reader is scrolled
  waits until they return to the top (`_applySlots` / `_reportEngagement`).
- **The splash fades out over the app** instead of the app crossfading in over
  the splash. A crossfade blends two semi-transparent layers, which on a light
  theme washes the brand field through white and reads as a flash.

### 9.4 The reveal uncovered a transition in progress

`markFeedFinal()` is followed by `notifyListeners()`, so the shell rebuilds in
the next frame — and starting the fade in that same frame uncovered Discover
mid-crossfade, i.e. the feed fading in over itself. Now Discover's `_crossfade`
is **instantaneous while the launch holds** (behind an opaque screen there is
nothing to smooth), and `StartupGate` waits one post-frame callback before
starting the fade. Costs ~16 ms; guarantees what is revealed is settled.

### 9.5 Consequence: the permission sheet had to be deferred

With the shell live during the splash, `_handleAuthLocationFlow` could push the
location explainer as a route — which sits **above** the splash. It now awaits
`LaunchSequence.ready` first.

Two new tests in `feed_composer_test.dart` pin the insertion behaviour that
justifies the slot gate: composing a slot lengthens the list, and every organic
card below the insertion point shifts by one.

---

## Part 10 — Round three: the blink was a rule I had defended

Splash confirmed fixed. The feed still blinked, and the report was precise:
*after* the splash, *after* the feed had appeared. That timing named the bug.

### 10.1 `visibleIsPlaceholder` was the blink

`FeedArrival` had a rule that a placeholder — a page read off the disk, or the
chronological stand-in — may always be replaced outright, on the argument that
leaving a reader on stale posts is worse than moving them. That argument holds
while nobody is looking and is wrong the moment somebody is.

The failure path is the ordinary one, not an edge case:

1. the feed request outruns `LaunchSequence.deadline` (cold ranking backend,
   slow mobile data);
2. the splash hands over on the placeholder — which is exactly what a
   placeholder is *for*;
3. the ranked page lands a second later, `visibleIsPlaceholder` installs it
   unconditionally, `_feedGeneration` bumps, Discover re-keys its list, and the
   **entire feed crossfades** in front of someone who just started reading.

Part 8 of this document called that "one upgrade… acceptable, and it's rare".
It is not rare on this backend, and it is the blink.

**The rule is gone.** The placeholder cases that must still land are covered by
rules that already existed: during the launch nothing is on screen (rule 2), a
tab switch or pull-to-refresh is the user asking (rule 3), and a swap on a
hidden tab is unseeable (rule 6). What remains — a better page arriving on its
own, at a screen someone is reading — is **offered**, like every other automatic
rebuild in the app. `_worthOffering` already returns true when the visible page
is a placeholder, so the pill appears and one tap applies it.

`visibleIsPlaceholder` is still *taken* by `FeedArrival.installs` and
deliberately no longer decides anything: the call site keeps stating the fact,
and the rule stays the only place that says what it is worth.

### 10.2 The deadline was set too tight to be the only defence

`LaunchSequence.deadline` **2200 ms → 3000 ms**, and
`AppProvider._rankingPatience` **1200 ms → 2600 ms**.

Neither costs anything on a healthy launch — the splash lifts the moment the
feed is final — so they bound only the slow path. The old patience value was
actively harmful: it pre-empted a ranking that was going to arrive at 1.5 s with
a chronological page at 1.2 s, for no gain, because the splash was going to keep
holding either way and nobody was waiting on the stand-in. It now sits just
short of the deadline, so the stand-in is painted only when the launch is
genuinely about to stop waiting.

### 10.3 A reconnect was masquerading as a user request

`_SyncOnReconnect` calls `refreshAll()`, which reported
`FeedInvalidation.explicit` — i.e. "the user asked for this" — so the feed was
replaced outright. A connection coming back is the app noticing, not a person
asking, and connectivity flapping during a launch could therefore replace the
feed twice. New `FeedInvalidation.reconnected` (quiet, offered);
`refreshAll` takes the reason from its caller.

### 10.4 I had taught the app to think it was offline

`NotificationStore.refresh()` called `NetworkHealth.failure()` on **any**
exception — my own addition in Part 8. At cold start the Firebase→Supabase token
exchange is still in flight, so that query can return an RLS rejection: a
perfectly reachable server saying *no*. Two of those tipped
`ConnectivityProvider` into probing, a slow probe published "offline", recovery
published "online", and the reconnect handler refreshed the whole app. A
permissions answer was being laundered into a feed reload. Now only
`TimeoutException` and `SocketException` count as evidence about the network.

### 10.5 Tests

650 total (+6). The arrival suite's `'…but lands immediately while they are
still at the top'` asserted the **opposite** of the new contract and now pins
it, with the failure it caused written into the test. New end-to-end cases in
`feed_launch_test.dart`: a ranking that overran the splash is offered and moves
no cards; applying it is what bumps the generation; a reconnect rebuilds
quietly.

### What the user will see now on a slow launch

Splash → real posts (chronological) → a **"New recommendations available"**
pill. One tap applies the ranked page and returns them to the top. No card moves
unless they ask. On a healthy launch the ranked page wins the race outright and
the pill never appears.

---

## Part 11 — Round four: measured on a device, not reasoned about

Rounds 1–3 were argued from the code. Round 3 did not fix the blink, and it
should not have been shipped on reasoning alone. With a Galaxy S20+ (Android 13)
on adb, both remaining defects were found in one launch trace and one set of
captured frames.

### 11.1 The blink: a rebuild that changed nothing still re-keyed the list

Instrumented `_install`, `LaunchSequence` and `StartupGate`, then took a cold
launch trace:

```
+0ms      [LAUNCH] begin
+970ms    FEED_INSTALL gen=1  source=fallback  placeholder=true   19 posts  splashUp=true
+1336ms   StartupGate created
+3002ms   handing over (deadline)          ← ranking not back yet
+5568ms   FEED_INSTALL gen=2  source=ranked  placeholder=false  19 posts  splashUp=false
```

Nineteen posts, then nineteen posts — **the same nineteen in the same order**,
because the disk cache is written from the previous session's ranked page. So
`FeedArrival` admitted it precisely because it moved nothing (`!differsVisibly`),
and `_install` then bumped `_feedGeneration` **unconditionally**. Discover keys
its list on that, so the entire feed tore down and crossfaded — a blink carrying
no information whatsoever.

Rounds 1–3 all looked at *which snapshots may arrive* and never at *what
arriving costs*. The two answers disagreed, and the disagreement was the bug.

**Fix:** the generation now means "what the reader is looking at changed", and
uses the **same predicate** `FeedArrival` uses. A rebuild admitted *because it
moves nothing* can no longer move anything. `resetImpressions` is gated with it,
so an identical page also stops re-sending impressions the engine already has.

Verified — three consecutive cold launches, `gen=1` before and after handover:

```
+544ms   gen=1  fallback  placeholder=true   splashUp=true
+3080ms  lifted
+3648ms  gen=1  ranked    placeholder=false  splashUp=false   ← no bump, no re-key
```

### 11.2 The double splash: the logo left the screen

`NormalTheme` — which the Flutter embedding applies *before* the first frame —
was `?android:colorBackground` on a Light parent, i.e. **white**. Round 3 changed
it to the brand colour, which removed the white flash but not the defect. Frames
captured from the device showed why:

| frames | what is on screen |
|---|---|
| f01–f08 | brand field **+ badge** (launch drawable) |
| **f09** | brand field, **no badge** ← the logo vanishes |
| f10–f11 | brand field + badge (Flutter's splash) |
| f12 | the feed |

Logo → **no logo** → logo. That is what "the splash loads twice" was: a flat
colour has no badge, so the mark dropped out for about a second.

**Fix:** `NormalTheme.windowBackground` → `@drawable/launch_background`, the same
drawable `LaunchTheme` uses, in both `values/` and `values-night/`.

Verified by pixel measurement — the badge's bounding box in the final Android
window frame and in Flutter's first frame:

```
g12 (Android window)  X=378  Y=1038  324×324  centre (540,1200)
g13 (Flutter splash)  X=378  Y=1038  324×324  centre (540,1200)
```

Identical. The handoff is not merely smooth, it is invisible. Eleven consecutive
frames across the Android phase are byte-identical.

### 11.3 What real users actually get

Debug builds are JIT and misleading — 700 ms just to construct `AppProvider`.
An AOT profile build on the same device and backend:

```
+19ms    gen=1  fallback  placeholder=true   splashUp=true
+54ms    StartupGate created
+1477ms  gen=1  ranked    placeholder=false  splashUp=true      ← behind the splash
+1477ms  handing over (feed ready)                              ← not the deadline
+1494ms  lifted
```

**Zero installs after handover.** The splash lifts on *feed ready*, not on the
deadline, and what is revealed is the finished ranked feed — the launch behaving
exactly as designed. Second run: 1241 ms. The 3 s deadline is now what it was
meant to be — a bound that is not normally reached.

### 11.4 Instrumentation kept

`[LAUNCH]` and `[FEED_INSTALL]` traces are retained. They are what made this
diagnosable, they match the logging conventions already in this codebase, and
the acceptance criterion for any future launch regression is now a one-line grep:

```
adb logcat -s flutter:V | grep -E "FEED_INSTALL|lifted"
```

**A generation bump after `lifted` is a blink.** Nothing else needs to be argued.

---

## Part 12 — Round five: why the splash differed between phones

The feed was confirmed fixed. The splash still "loaded twice" — and, critically,
**not on every device**. A second phone (Galaxy A21s, Android 12, 3-button
navigation, 720×1600) made the cause obvious in one trace.

### 12.1 The launch can finish before the splash widget exists

Galaxy A21s, cold launch:

```
+1154ms  AppProvider created
+2529ms  FEED_INSTALL gen=1 (disk cache)
+3576ms  handing over (deadline)      ← the launch is OVER
+4322ms  StartupGate created          ← the splash widget is born 750ms LATER
```

`LaunchSequence.begin()` is armed in `main()`, but nothing can be **painted**
until Flutter has built a widget tree — and on a low-end device that is seconds,
not frames. `StartupGate` woke up after the finish line, found `_open == false`,
painted a fresh brand screen, and faded it out a microtask later.

So the user saw the Android splash, the app become ready, and *then* a second
brand screen appear and disappear. Precisely "it clearly loads two separate
splash screens".

**This is also the whole explanation for the device-to-device inconsistency.**
On the Galaxy S20+ the gate is created at +54 ms (AOT) or +905 ms (debug) —
always before the handover — so the splash is one continuous thing and the bug
is invisible. The slower the phone, the more likely the gate arrives late. It was
never a rendering difference; it was a race between the widget tree and the
launch, and cheap hardware loses it.

**Fix:** `LaunchSequence.handedOver`, read synchronously by `StartupGate` at
construction. If the launch is already over, the gate opens immediately —
`_open = true`, `_splashRetired = true`, no splash, no fade. The Android window
background has been showing the badge continuously the whole time, so the app
simply appears underneath it and the logo never leaves the screen.

Verified, two runs each:

```
A21s   +4322ms StartupGate created
       +4323ms launch already over — handing straight to the app, no Flutter splash
S20+   +905ms  StartupGate created      (before the +3176ms handover — normal hold)
       +4049ms FEED_INSTALL gen=1 ranked splashUp=false   ← still no blink
```

### 12.2 What was ruled out by measurement, not argument

Worth recording, because each was a plausible theory that turned out to be wrong:

- **A badge size/shape change at the Android→Flutter handoff.** Measured: white
  tile 326×326 at X 377..702, Y 1037..1362 in *both*; red logo identical to
  within one pixel. The ~10 000 differing pixels are two rasterizers resampling
  the same PNG, nothing more.
- **The Android 12 splash icon being a big disc.** The comment in
  `values-v31/styles.xml` says so, but the asset is a 288 px canvas with the
  **116 px badge centred** — already correct.
- **A vertical jump from the navigation-bar inset.** One frame suggested a 22 px
  shift; deterministic sampling of both phases showed centreY 1200 in both.
- **Samsung's amber display filter on the A21s.** Made captured frames read as
  flat brown and briefly looked like a blank window. It is a display-level
  filter that `screencap` records; the app was rendering correctly underneath.

### Still not verified on a device

The launch and the feed are now measured (Part 11). These are not:

1. **`markAllRead` on a large inbox.** The realtime burst is absorbed locally,
   but it is worth confirming against a real account with 50+ unread rows that
   the badge makes exactly one transition.
2. **The notification centre against real data.** Sectioning, grouping and
   priority are unit-tested as pure functions; they have not been seen rendering
   a real register.
3. **The offline notification path.** The contracts are tested; the actual
   airplane-mode behaviour has not been exercised on the device.
