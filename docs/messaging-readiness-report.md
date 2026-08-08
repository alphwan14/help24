# Messaging Readiness Report

**Date:** 2026-08-08
**Device:** Samsung **SM-G986U (Galaxy S20+ 5G)**, **Android 13 / SDK 33**, physical, over ADB (`R5CN218ZKZY`). No emulator.
**Build:** `flutter build apk --release`, 68.8 MB, `adb install -r`, production backend (no dart-defines).
**Scope:** Stage 1 (investigate) → Stage 2 (conversation identity) → Stage 3 (cache/readiness). No backend, schema or migration change in any stage.

---

## Root cause

Two independent defects, both client-side. The database schema was correct throughout and was never modified.

### §D1 — "Start conversation" was really "the lookup has not run yet"

`ChatScreen.initState` branched on `widget.conversation.id`:

```dart
if (_chatId.isNotEmpty) { …hydrate, realtime… }
else { /* Pending chat: show empty state */ _loadingMessages = false; }
```

An empty id meant *"the caller did not tell me the id"*. It was treated as *"no conversation exists"*. Four entry points construct `Conversation(id: '')` — provider profile, applications, post detail, saved — so all four showed **"Start the conversation"** over a real thread.

The lookup existed and was correct; it just ran inside `createChat` on **first send**. That is exactly why sending a message made the history appear underneath it.

Production data showed the damage: one participant pair held **12 chat rows, 136 messages fragmented across them, 6 of them empty**.

### §D2 — Provider Profile silently dropped the post context

`provider_profile_screen` built its `Conversation` with **no `postId`**, so it targeted the `post_id IS NULL` row while every other entry point targeted `post_id = X`. Under `idx_chats_unique_null` / `idx_chats_unique_post` those are **genuinely different conversations**. Live data had a job question ("How much do you charge for this job") stranded in the general thread.

### §S3 — Why messages visibly loaded, measured rather than assumed

Instrumented the real open path (`MEMO_PAINT` / `CACHE_PAINT` / `NET_PAINT`) and measured on the S20+ against production:

| Case | Cached paint | Server page |
|---|---|---|
| Thread opened before on this install | **+25 ms** | +436 ms |
| Thread **never** opened on this install | **never** | **+522 ms** |

So the cache worked — but it was populated **only as a side effect of opening that specific chat**. Nothing pre-warmed it, so every conversation the user had not already opened on that install paid a full **522 ms spinner**. That is the "messages start loading every time" complaint.

A second, smaller cost: `_hydrateFromCache` is async (SharedPreferences handle + JSON decode), so even a warm thread showed a spinner for the first frame or two (+25 ms).

---

## Architecture chosen

**No new cache was introduced.** `CacheService` + `SessionScope` already provided the right structure — conversation-scoped **and** user-scoped keys (`help24_cache_messages_<uid>_<chatId>`), with a purge at every session boundary. Stage 3 builds on it in two places:

1. **A read-through in-memory mirror** of the *same* SharedPreferences entries, under the *same* scoped key. Not a second cache — it cannot disagree with disk about ownership. It makes the first paint synchronous, removing the async gap.
2. **A bounded startup prefetch** that warms the most recent threads through the existing `getMessages` page and the existing `saveMessages` writer.

Behaviour is stale-while-revalidate throughout: `cache → render immediately → background sync → reconcile → persist`.

---

## Files changed

### Stage 2 (commit `e0e70dd`, pushed)

| File | Change |
|---|---|
| `lib/services/chat_resolution.dart` | **New.** Four-state resolution, `showsStartConversation` gate, `canonicalPair` |
| `lib/services/chat_service_supabase.dart` | **New read-only** `findExistingChat` / `findMostRecentChatForPair` (create nothing; report `ok` separately from `row`); `createChat` shares `canonicalPair` |
| `lib/screens/messages_screen.dart` | Resolve on open; `_beginExistingChat()` shared by both paths; `resolveMostRecent`; empty state gated |
| `lib/screens/provider_profile_screen.dart` | `resolveMostRecent: true` |
| `test/chat_resolution_test.dart` | **New**, 19 tests |

### Stage 3

| File | Change |
|---|---|
| `lib/services/cache_service.dart` | In-memory mirror + synchronous `peekMessages`; `MessageMemoScope` registers with `SessionScope` |
| `lib/main.dart` | Registers `MessageMemoScope` before any cache read |
| `lib/providers/app_provider.dart` | `_prefetchRecentThreads` — bounded, session-budgeted warm-up |
| `lib/screens/messages_screen.dart` | Synchronous first paint from the mirror; paint instrumentation |
| `test/message_cache_memo_test.dart` | **New**, 13 tests |

---

## Cache lifecycle

| Moment | Behaviour |
|---|---|
| App start | `SessionScope.purgeForeignScopes` removes any other account's keys; `MessageMemoScope` registered |
| Auth restored | `loadConversations` hydrates the list **from disk first**, then subscribes |
| Conversation stream first answer | `_prefetchRecentThreads` warms the **5 most recent** threads (one 30-message page each) |
| Messages tab | Paints from the hydrated list — no wait for Supabase |
| Chat open | `peekMessages` (sync, first frame) → `_hydrateFromCache` (disk) → realtime page |
| Incoming message | Realtime merges and `_scheduleCacheSave` persists |
| Outgoing message | Optimistic entry immediately; outbox survives restart; reconciles on send |
| Offline | Cached list and threads readable; an empty realtime emission **never** wipes the screen |
| Reconnect | Realtime resubscribes; merge is id-based, so no duplicates |
| Logout | `SessionScope.endSession` resets providers, clears the mirror, purges uid-scoped keys |

### Prefetch bounds

At most **5 conversations per session**, most recent first; one existing 30-message page each; once per chat; skipped when already mirrored; sequential; never offline; failures silent.

**A real bug was caught on-device here.** The first implementation used a *per-call* counter. The conversation stream emits on every poll and every realtime nudge, so each emission warmed the *next* five — it would eventually download every thread the account had. Detected because a conversation at list position 7 turned up warm with a 5-thread limit. The budget is now `_prefetchedThreads.length` (per session), pinned by a test that reproduces the old behaviour and fails on it.

---

## Tests

```
flutter test      →  778 passed  (Stage 2: +19, Stage 3: +13)
flutter analyze   →  0 errors in all changed files
```

Backend untouched, so no backend suite was re-run for Stage 3; the last full run was **594 passed** at commit `2416e32`.

Notable cases: offline → `unresolved` never `absent`; reversed participant order yields the same key; a per-call prefetch budget drains the whole list (the caught bug); account B cannot peek A's thread for the same chat id; `MessageMemoScope` is a `SessionScoped` member; sign-out drops the mirror.

---

## S20+ results

### Conversation identity (Stage 2)

Predictions were taken from the database **before** each test and matched exactly.

| Entry point | Resolved | Result |
|---|---|---|
| Messages tab | `9dc93193` | ✅ |
| **Provider Profile → Message** | `9dc93193`, `mostRecent=true` | ✅ **previously showed "Start conversation"** |
| Application → Message (post with no chat) | `absent`, `mostRecent=false` | ✅ correctly *does* offer to start |
| First send | created `0337ad57`, 1 message | ✅ exactly one row |
| Application → Message (re-entry) | `0337ad57` | ✅ no duplicate |
| **Profile → Message afterwards** | `0337ad57`, `mostRecent=true` | ✅ **converges with Application**, post banner adopted |
| Offline | `unresolved` | ✅ *"Couldn't open this conversation"* + retry |
| Try again after reconnect | `0337ad57` | ✅ |

Post-session database: **21 chats (was 20), 1 created, 0 duplicate keys, 0 empty chats.**

### Online timing (Stage 3)

| Scenario | Before | After |
|---|---|---|
| Thread never opened on this install | `NET_PAINT` **+522 ms** (spinner) | **`MEMO_PAINT` +0 ms** |
| Thread already opened | `CACHE_PAINT` +25 ms | **+0 ms** |
| Server refresh (silent, behind the rendered thread) | — | +360–496 ms |
| Cold app start | 831 ms | 789–898 ms (prefetch does not block) |
| Prefetch cost | — | 1 round, `session budget 5/5`, observed over 100 s and multiple emissions |

Headline: **522 ms → 0 ms** for the first open of a conversation.

### Offline timing

Airplane mode confirmed by `ping → Network is unreachable`, then the process force-stopped and relaunched.

| Check | Result |
|---|---|
| Cold start offline | **421 ms** |
| Messages tab | ✅ full cached list |
| Open conversation | ✅ **`CACHE_PAINT` +20 ms**, message readable |
| False "Start conversation" | ✅ none |
| Blocking spinner for cached history | ✅ none |

(`CACHE_PAINT` rather than `MEMO_PAINT` is correct: a fresh process has an empty mirror, so disk serves it.)

### Reconnect

`NET_REFRESH … n=1` — same single message, **no duplicates**. Realtime resubscribed (`RealtimeSubscribeStatus.subscribed`) on both channels.

### Logout / login isolation

Account **A** = `nlAJ…` (alphlincoln18), account **B** = `k4DZ…` (alphwan14). Both pre-existing; no account was created.

- Logout A → `[SESSION] purged 12 user-scoped key(s)`.
- Login B → Messages showed **B's own** conversations, including B's separate Babel Damien chat ("Medical Transport Needed") and Timothy Oyombe.
- **All three A-only conversations were absent** — Babel/"Fundi wa Rangi" (`03c2bd67`, cached for A minutes earlier), Babel/"cleaners" (`697d2bc3`), Pauline Oyombe/"Airtel Wifi" (`d2b18f57`).
- Login A again → A's conversations restored; **B's own chats absent**.

Isolation verified in **both directions**, with the strongest possible discriminator: a thread cached for A seconds before the switch.

---

## Remaining messaging issues (evidence-backed only)

- **Empty chat rows on a failed first send.** `_ensureChatCreated()` is called from six send paths and creates the row *before* the payload lands; if the send then fails, an empty chat persists. Six such rows exist in production from June. **No reproduction in any session here** — reported, not fixed.
- **Historical fragmentation is not cleaned up.** The 12-row pair and the 6 empty rows remain. That is a production-data decision and needs explicit approval.
- **Messages tab lists one row per post-scoped chat**, so the same person can appear several times. That is the identity model working as designed, not a defect.
- **Transient realtime error during reconnect** (observed once): `ERROR P0001 invalid column for filter chat_id` on the `chat_messages` channel, which **self-healed 6 s later** with a successful resubscribe. Non-blocking; recorded because it was seen, not because it broke anything.
- **Prefetch covers 5 threads.** A user who opens their 6th-most-recent conversation on a new install still waits for the network once. Deliberate — the alternative is downloading everything.
