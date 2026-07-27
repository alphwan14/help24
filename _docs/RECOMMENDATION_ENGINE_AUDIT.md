# Discover Feed — Audit of the Existing System

**Date:** 2026-07-27
**Scope:** every surface that decides *what a user sees and in what order* — Discover,
search, filters, Jobs, urgent requests, provider discovery, saved items, sponsored slots.
**Status:** pre-implementation. Nothing in this document proposes a change; it records
what the system does today and where it breaks.

---

## 1. Inventory — every read path that produces a ranked list

| # | Surface | Entry point | Query | Ordering |
|---|---------|-------------|-------|----------|
| 1 | Discover feed | `discover_screen.dart:465` → `AppProvider.loadPosts` | `PostService.fetchPosts` | `created_at DESC`, `LIMIT 50` |
| 2 | Discover (client re-filter) | `AppProvider.filteredPosts` | in-memory `where()` | **none** (preserves fetch order) |
| 3 | Jobs tab | `jobs_screen.dart:97` → `AppProvider.loadJobs` | `PostService.fetchJobs` | `created_at DESC`, `LIMIT 50` |
| 4 | Jobs (client re-filter) | `jobs_screen.dart:99-113` | in-memory `where()` | **none** |
| 5 | Urgent requests | `AppProvider.loadUrgentPosts` | `PostService.fetchUrgentPosts` | `created_at DESC`, `LIMIT 5`, then client-side **nearest-first** |
| 6 | Saved shortlist | `SavedService` → `PostService.fetchPostsByIds` | `id IN (...)` | **none** (Postgres physical order) |
| 7 | My posts | `PostService.getMyPosts` | `author_user_id = me` | `created_at DESC` |
| 8 | Sponsored slots | `PromotionService.fetchSlots` → `GET /promotions/slots` | `promotion_campaigns` + `posts!inner` | quality rank → rotation hash |
| 9 | Provider discovery | — | — | **does not exist** |

Everything except #5 and #8 is *recency only*.

---

## 2. Ranking signals in use today

There are exactly **three**, and only two of them touch the main feed:

### Signal A — recency (`created_at DESC`)
[`post_service.dart:154`](../mobile-app/lib/services/post_service.dart#L154), [`:265`](../mobile-app/lib/services/post_service.dart#L265)
The sole ordering signal for Discover and Jobs. Applied in the database, before the
`LIMIT`, so it also decides *membership* of the result set — see §3.1.

### Signal B — proximity (urgent banner only)
[`app_provider.dart:305-323`](../mobile-app/lib/providers/app_provider.dart#L305-L323) `_sortUrgentByProximity`
Haversine distance, nearest first, `created_at` as tie-break; posts without coordinates
sort last. Correct as far as it goes — but it runs on **5 rows** that were already
selected by recency, and it is never applied to the Discover feed itself.

### Signal C — sponsored quality rank
[`serving-logic.ts:132`](../backend/src/promotions/serving-logic.ts#L132) `rankScore`
`0.5 × bayesian rating + 0.3 × completion rate + 0.2 × proximity`, then a
bucket-seeded rotation hash. This is the only real *scoring* code in the product,
and it only orders **paid** slots. Ironically the sponsored lane is better ranked
than the organic one.

### Non-signals (present in the data, unused for ranking)
| Data | Where it lives | Used for ranking? |
|---|---|---|
| `posts.latitude/longitude` | migration 018 | only in the 5-row urgent banner |
| `posts.is_urgent` / `urgent_expires_at` | migration 018 | membership filter only, never a boost |
| `posts.urgency` (`urgent`/`soon`/`flexible`) | base schema | filter only |
| `users.profession` (slug, 482-value registry) | migrations 086 / 089 | **never read by the feed** |
| `professions.category_id` → `categories.id` | migration 089 | seam exists, nothing uses it |
| `provider_reputation.*` (bayesian, completion, dispute, tier) | migration 055 / view 079 | fetched for *display* only ([`post_service.dart:60`](../mobile-app/lib/services/post_service.dart#L60)) |
| `applications` (per-post count) | base schema | rendered on the card, not scored |
| `saved_items` | migration 082 | personal shortlist only |
| `posts.status` (`open`/`assigned`/…) | migration 030 | **not filtered in the feed at all** |

### Signals that do not exist anywhere
Views, impressions, click-through, dwell, search history, category affinity,
provider availability, verification/business flags, per-skill matching,
time-of-day context, diversity, author frequency capping.

---

## 3. Weaknesses

Ordered by how much damage each one does.

### 3.1 — The candidate set is chosen by recency, so ranking can never fix it 🔴
`fetchPosts` is `ORDER BY created_at DESC LIMIT 50`. Whatever ranking is layered on
top can only reorder *those fifty rows*. The best-matching, nearest, most urgent
electrical job in the city is invisible the moment 50 newer posts of any kind exist.

At today's volume this is masked. At 10k posts it is the whole problem: the feed
degrades into "the last few hours of activity, nationwide". **Any ranking work that
does not also fix retrieval is cosmetic.**

### 3.2 — Location is captured, stored, and then thrown away 🔴
`LocationProvider` holds `latitude`/`longitude` ([`location_provider.dart:61-62`](../mobile-app/lib/providers/location_provider.dart#L61-L62)),
persisted per-user. `PostFilters` has **no coordinate fields at all**
([`post_service.dart:10-36`](../mobile-app/lib/services/post_service.dart#L10-L36)). The
feed request never sees where the user is.

The only proximity that reaches Discover is `_priorityLocationCity`
([`app_provider.dart:883`](../mobile-app/lib/providers/app_provider.dart#L883)) — which is
**set but never read**: no `filteredPosts` branch, no sort, nothing. Dead code that
documents an intent that was never wired.

Where location *is* used for filtering, it is `ilike '%Nairobi%'` against a free-text
`posts.location` column ([`post_service.dart:116`](../mobile-app/lib/services/post_service.dart#L116)).
That is city-string matching — explicitly what we do not want — and it is also wrong:
`area` and `city` are ANDed as two independent substring matches on the same column.

### 3.3 — Profession is the strongest available signal and is completely unused 🔴
Migration 089 built a 482-profession catalogue with aliases, tags, and a
`category_id` link to `categories` — described in its own header as "the seam for
future provider↔request matching". Nothing consumes it. An electrician's Discover
feed is byte-identical to a caterer's.

### 3.4 — Urgent posts are quarantined instead of boosted 🟠
`is_urgent` posts are pulled into a separate 5-item banner behind an "Urgent" pill.
In the main feed an emergency plumbing request 800 m away ranks exactly the same as
a flexible request 200 km away posted one second later. Urgency is a *filter*
(`eq('is_urgent', true)`), never a decaying boost.

### 3.5 — Filtering is duplicated client + server, and the two disagree 🟠
`AppProvider.filteredPosts` ([`:906-967`](../mobile-app/lib/providers/app_provider.dart#L906-L967))
re-applies the same filters the server already applied. The implementations differ:

| Filter | Server | Client |
|---|---|---|
| search | `title` OR `description` OR `category` | `title` OR `description` OR `category` OR **`location`** |
| price | skipped when `min=0` / `max=100000` | **always applied** (`post.price` must be in range) |
| category | `IN (...)` on `posts.category` | `contains(post.category.name)` |

The price divergence is a real bug: a post with `price = 0` ("negotiable") is returned
by the server and then hidden by the client whenever the slider start is above 0.

### 3.6 — Closed work is still advertised 🟠
Neither `fetchPosts` nor `fetchJobs` filters `status`. Posts that are `assigned`,
`completed`, `disputed` or `cancelled` sit in the feed alongside open ones. The
sponsored path gets this right (`.eq('posts.status','open')`,
[`serving.service.ts:109`](../backend/src/promotions/serving.service.ts#L109)) — the
organic path does not.

### 3.7 — Every filter change refetches the entire feed 🟠
`setSearchQuery` calls `loadPosts()` on **every keystroke**
([`app_provider.dart:823-828`](../mobile-app/lib/providers/app_provider.dart#L823-L828)),
unthrottled and unsequenced. Sponsored slots are debounced 600 ms
([`discover_screen.dart:127`](../mobile-app/lib/screens/discover_screen.dart#L127)); the
organic feed is not. Typing "electrician" fires 11 full feed queries, each returning
50 rows with joined users + images + applications, and a slow early response can
land after a fast later one and overwrite it.

### 3.8 — The feed row is far too heavy 🟠
Every feed query selects `applications(*, users!applicant_user_id(...))` — the full
applicant list, with each applicant's user row, for all 50 posts. The card only needs
a *count*. At 30 applicants per post this is ~1500 joined rows per feed load.

### 3.9 — No pagination, anywhere 🟠
`PostFilters.limit = 50` / `offset = 0` are never varied. There is no infinite scroll,
no cursor. The feed is hard-capped at 50 items and the 51st post is unreachable.

### 3.10 — Trust data is fetched but never ranked 🟡
`_warmReputations` pulls `public_provider_reputation` for every visible author
specifically so cards can *show* a rating. Bayesian rating, completion rate, dispute
rate and tier are all in hand, per author, at feed-build time — and contribute
nothing to ordering.

### 3.11 — Jobs is a second, weaker feed 🟡
`fetchJobs` re-implements `fetchPosts` minus the type filter and with a narrower
search (no `category` clause, [`post_service.dart:257-261`](../mobile-app/lib/services/post_service.dart#L257-L261)).
Jobs are `posts` rows with `type='job'`. Two code paths, two behaviours, one table.
The Jobs tab's employment-type filter is also client-side over an unranked 50-row page.

### 3.12 — No behavioural data is collected at all 🟡
There is no view/impression/open/dwell tracking of any kind for organic posts.
Sponsored cards *are* instrumented (`PromotionTracker` → `POST /promotions/events`),
so the product tracks what advertisers pay for and nothing about what users actually
want. There is no substrate for signals 9 (behaviour) or 10 (search history) to
be built on — it has to be created.

### 3.13 — No diversity, no author capping 🟡
Ordering is purely `created_at DESC`. One provider posting ten offers in a minute
owns the top ten rows of everyone's feed. Nothing in the pipeline notices.

### 3.14 — Provider discovery does not exist 🟡
There is no browsable provider surface. `ProviderProfileScreen` is reachable only by
tapping through a post or an applicant card. "Find me an electrician" has no answer
in this product today.

### 3.15 — Indexes are absent for every ranking dimension 🟡
Present: `idx_posts_created_at`, `idx_posts_author_user_id`, `idx_posts_status`,
`idx_posts_is_urgent`, `idx_posts_urgent_expires_at`, `idx_posts_lat_lng`,
`idx_posts_active`.

Missing for anything beyond recency: no composite `(status, archived_at, type,
created_at)` for the actual feed predicate; `idx_posts_lat_lng` is a plain btree on
`(latitude, longitude)` which **cannot serve a bounding-box query** on both axes;
no index on `category`; no text-search index (every search is `ilike '%…%'`, i.e. a
guaranteed sequential scan).

---

## 4. What is already right (and must be preserved)

Not everything needs replacing. These are load-bearing and correct:

- **Sponsored integration is finished and principled.** `FeedComposer`
  ([`feed_composer.dart`](../mobile-app/lib/utils/feed_composer.dart)) never reorders
  organic results, never clusters slots, never shows a sponsored duplicate of an
  organic post, and shows nothing when the feed is thin. Requirement 15 is met.
- **`serving-logic.ts` is the right shape**: pure functions, no I/O, no Nest imports,
  unit-tested separately from the service that feeds it. The ranking engine should be
  built the same way.
- **The settings pattern** (`promotion_settings` + `PromotionSettingsService`, code
  defaults merged under DB overrides, 60 s cache) is exactly how ranking weights
  should be tuned without an app release.
- **Graceful degradation is a stated contract**: promotions never block or break the
  organic feed. A ranking backend must inherit that contract.
- **`provider_reputation` is a derived, idempotent, server-authoritative table** with
  no client-maintained counters. It is a trustworthy ranking input as-is.
- **Reference data is canonical**: categories (070) and professions (086/089) are
  slug-keyed registries with bundled offline copies. Matching can rely on them.
- **Offline/cache/error handling** in `AppProvider` distinguishes "failed to load"
  from "nothing here" and survives sign-out correctly. Preserve it.

---

## 5. Conclusion

The product has production-grade *plumbing* — reputation, reference data, promotion
serving, escrow, error mapping — and an MVP *feed*: one `ORDER BY created_at DESC
LIMIT 50` with client-side re-filtering on top.

Every signal the brief asks for is either already in the database and unread
(location, profession, urgency, reputation, applications, status), or has no
substrate at all and must be created (behaviour, search history, availability,
verification, engagement counters).

The single most important finding: **retrieval, not ranking, is the bottleneck.**
Scoring the newest 50 rows better does not build a recommendation engine. Candidate
generation has to become signal-aware first, and the ranking layer has to run
server-side where it can see the whole corpus, be tuned without a release, and be
explained.

See [`RECOMMENDATION_ENGINE_ARCHITECTURE.md`](./RECOMMENDATION_ENGINE_ARCHITECTURE.md)
for the design that follows from this.
