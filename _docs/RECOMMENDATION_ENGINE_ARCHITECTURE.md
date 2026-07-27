# Help24 Recommendation Engine — Architecture (Generation 1)

**Companion to:** [`RECOMMENDATION_ENGINE_AUDIT.md`](./RECOMMENDATION_ENGINE_AUDIT.md)
**Status:** implemented — see §11 for the file map.

> Help24 exists to connect the right person with the right opportunity as quickly
> as possible. This engine optimises for **successful matches**, not clicks.

---

## 1. The one decision everything else follows from

The audit's headline finding: the feed's candidate set is `ORDER BY created_at DESC
LIMIT 50`. Re-sorting that page cannot produce relevance, because the relevant post
is usually **not in it**.

So the engine is split the way every production ranking system is split:

```
  ┌──────────────────┐   ┌──────────────┐   ┌──────────────┐   ┌────────────┐
  │  RETRIEVAL       │ → │  SCORING     │ → │  COMPOSITION │ → │ HYDRATION  │
  │  (Postgres)      │   │  (pure TS)   │   │  (pure TS)   │   │ (Postgres) │
  │  ~400 narrow rows│   │  score+explain│  │ diversity,   │   │ 20 full    │
  │  4 signal-aware  │   │  15 signals  │   │ anti-spam,   │   │ rows, same │
  │  pools, indexed  │   │  no I/O      │   │ page slice   │   │ shape as   │
  └──────────────────┘   └──────────────┘   └──────────────┘   │ today      │
                                                                └────────────┘
```

Retrieval is signal-aware so the *right* candidates are in the pool. Scoring is
pure and testable. Hydration only pays for the rows that survive — the feed now
transfers 20 heavy rows per page instead of 50.

**Where it runs:** the NestJS backend, `GET /feed`. Not the client, because
(a) the client can only rank what it fetched, (b) weights must be tunable without
an app-store release, (c) behavioural data must not be shipped to devices wholesale,
(d) explanations need a server-side trace.

**Degradation contract (inherited from promotions, non-negotiable):** if `/feed`
is slow, cold or down, `FeedService` falls back to the existing
`PostService.fetchPosts` Supabase path, unchanged. The feed never breaks because
ranking did. Timeout is 8 s.

---

## 2. Retrieval — `fn_feed_candidates`

One Postgres function, four **pools**, each independently limited and index-backed,
`UNION`ed and deduplicated. Pools exist so that a candidate can enter the set for
*any* reason that matters, not only for being new:

| Pool | Predicate | Why it exists |
|---|---|---|
| `nearby` | bounding box on `latitude`/`longitude` within `radius_km` | the nearest post must be reachable even if it is old |
| `affinity` | `category = ANY(viewer's profession + behaviour categories)` | the electrician's electrical job must be reachable even if it is old |
| `urgent` | `is_urgent AND urgent_expires_at > now()` | emergencies must never be paged out |
| `fresh` | no extra predicate | new posts must always get discovery |

Every pool also applies the **shared base predicate**: `archived_at IS NULL`,
`status = 'open'`, plus the caller's explicit filters (type, category, price,
urgency, difficulty, city/area, search). Explicit filters are *hard* — a user who
filters to Plumbing never sees anything else, regardless of score.

Each pool orders by `created_at DESC` and takes `pool_limit` (default 150); the
union is capped at `max_candidates` (default 400). Distance is computed in SQL
(haversine) when both sides have coordinates.

The function returns **narrow** rows: post scalars + author trust columns +
`provider_reputation` + `post_engagement` counters + `distance_km` +
`viewer_has_applied` + `is_own_post`. No joins to images or applications — those
are hydration's job.

### Bounding box, not `ilike '%city%'`
`radius_km` becomes a latitude/longitude window (`Δlat = r/111.045`,
`Δlng = r/(111.045·cos(lat))`), which a btree on `(latitude, longitude)` can serve.
Exact haversine then runs on the (small) windowed set. This is why the engine
**never uses city-string matching for proximity** — city matching remains only as
an explicit user filter.

---

## 3. Scoring — the signal registry

`backend/src/feed/ranking/` is **pure**: no Nest imports, no I/O, no clock reads
except an injected `now`. Every signal is one file implementing:

```ts
interface FeedSignal {
  key: SignalKey;
  weight(w: FeedWeights): number;                       // max points
  score(c: RankingCandidate, ctx: ViewerContext, cfg: FeedConfig): number | null;
}
```

`score()` returns `0..1`, or **`null` = not applicable** — which removes the signal
*and its weight* from that post's maximum. A viewer with no location does not get a
feed where every post lost 30 points; the distance signal simply does not participate.
That is what makes "no location permission" a first-class case rather than a
degenerate one.

`finalScore = Σ (weight × score)` over applicable signals, minus penalties.
Adding signal #16 is one file plus one registry line.

### The signals

| # | Key | Weight | Shape |
|---|---|---:|---|
| 1 | `distance` | **30** | `1 / (1 + (d/d₀)^p)`, `d₀=15 km`, `p=1.5`. 1 km→0.98, 5→0.84, 20→0.39, 100→0.06. No post coords → **0.5 (neutral, never punished)**. No viewer coords → `null`. |
| 2 | `profession` | **25** | viewer's profession → `professions.category_id` → `categories.name`. Exact category match 1.0; same profession *group* 0.55; alias/token hit in title+description 0.35. |
| 3 | `skills` | **10** | identical matcher over `user_skills` (secondary), best match × the skill's own weight. Table ships now, empty by default → `null`. |
| 4 | `urgency` | **18** | live `is_urgent` → piecewise-linear decay over anchors `[0h:1.0, 2h:0.85, 6h:0.6, 24h:0.25, 48h:0]`. Past `urgent_expires_at` → falls back to the `urgency` enum (`urgent` 0.5 × freshness, `soon` 0.25, `flexible` 0). |
| 5 | `freshness` | **10** | `0.5 ^ (hoursOld / 24)`. |
| 6 | `engagement` | **5** | intent over popularity: `0.5·sat(applications,4) + 0.3·sat(saves,5) + 0.2·sat(messages,5)`, `sat(x,k)=x/(x+k)`; views contribute nothing directly. **Crowding penalty:** a request/job past `crowd_threshold` (10) applications is multiplied by `threshold/count` — an over-subscribed request is a worse *match*, and matches are what we optimise. |
| 7 | `availability` | **5** | `offer` posts only (else `null`): `available_until > now` → 1.0; else `last_active_at` < 24 h → 0.5, < 7 d → 0.35, else 0.15. |
| 8 | `reliability` | **8** | `0.5·(bayesian/5) + 0.35·completion_rate + 0.15·(1−dispute_rate)`, blended toward neutral 0.5 by `confidence = min(1, completed_jobs/5)`. **A new provider is never punished for being new.** |
| 9 | `behaviour` | **12** | time-decayed affinity from `user_interactions`: `max(category, profession, 0.8 × author)`. |
| 10 | `searchHistory` | **6** | recent queries (7 d), token overlap with title+description+category, decayed by query age (half-life 48 h). |
| 11 | `timeOfDay` | **4** | config table of hour-range → category set. In-window 1.0, else 0.35 baseline (soft, never punitive). |
| 12 | `trust` | **5** | `0.4·verified + 0.2·business + 0.4·tier` (`trusted_professional` 1.0 → `new_provider` 0.0). |
| — | `ownPost` | **−25** | the viewer's own listing is never the opportunity they are looking for. Demoted, **never hidden**. |
| — | `alreadyApplied` | **−30** | already responded → strongly demoted. |

Signals 12 (diversity), 13 (anti-spam) and 15 (sponsored) are *not* scores — they are
composition rules, §4.

Every constant above lives in `feed_settings` (§6) and is a DB edit, not a release.

---

## 4. Composition — diversity, anti-spam, sponsored

`diversify()` walks the score-sorted list and greedily takes the highest-scoring
candidate that violates no constraint:

| Constraint | Default | Cost to break |
|---|---|---|
| `maxConsecutiveSameCategory` | 2 | 1 |
| `maxConsecutiveSameType` | 3 | 2 |
| `maxConsecutiveSameAuthor` | 1 | 4 |
| `maxPerAuthorPerPage` | 2 | 8 |

When **no** candidate is freely placeable, the pass takes the one whose
violation set is **cheapest** and breaks only that. Costs double, so breaking
both cosmetic constraints (1+2=3) still costs less than touching author capping
(4): variety is always given up before spam protection is.

Choosing per slot rather than switching a constraint off globally is
load-bearing. A fixed relaxation order gets this wrong in a way that is easy to
ship and hard to notice — and did, until the test suite caught it: when a page
is all one post type, `consecutiveType` blocks everything, a fixed order drops
the cheapest constraint (`consecutiveCategory`) which was never the blocker, and
a third consecutive plumber appears that nothing had asked to allow.

The feed therefore **never truncates and never reorders into nonsense** — it
degrades to pure score order in the worst case. Deterministic; same input always
yields the same output.

**Sponsored** is untouched. `FeedComposer` on the client already guarantees organic
order is never altered, slots never cluster, a sponsored post never duplicates an
organic one, and thin feeds show none. `/feed` returns organic results only; the
sponsored lane stays exactly where it is.

---

## 5. Behavioural substrate — `user_interactions`

Append-only, RLS-owner-scoped, one row per event:

```
kind ∈ impression | open | save | unsave | apply | message | hire
     | search | category_open | profile_open
```

Default event weights: `hire 8, apply 5, message 4, save 3, search 2,
category_open 1.5, open 1, profile_open 1, impression 0.05, unsave −3`.

`fn_user_affinity(user_id, halflife_days, lookback_days, limit)` returns
`(dimension, key, weight)` for `category` / `profession` / `author`, plus the
viewer's recent `search` queries — **one round trip**, bounded by
`(user_id, created_at DESC)` index and a 90-day lookback. Weight is
`Σ event_weight · exp(−age_days / halflife)`, normalised to `0..1`, half-life 14 days.

Ingest is `POST /feed/interactions`, batched and fire-and-forget from the client —
identical contract to `PromotionTracker`. Analytics never blocks or breaks the feed.

Retention: interactions older than 180 days are pruned by
`fn_prune_user_interactions()` (call from an existing sweep or a cron).

## 5b. Engagement counters — `post_engagement`

Read-time aggregation over `user_interactions` per post would be the N² the brief
warns against. Instead a narrow counter row per post is maintained by triggers on
`applications`, `saved_items` and `user_interactions`. `posts` itself is never
widened — the hot write path stays where it is.

---

## 6. Tuning without a release — `feed_settings`

Same shape and same service pattern as `promotion_settings`: `key TEXT PK,
value JSONB`, code defaults merged **under** DB overrides, 60 s in-process cache,
type-checked merge so a malformed row can never take the feed down.

Keys: `weights`, `distance`, `urgency`, `freshness`, `engagement`, `behaviour`,
`availability`, `trust`, `time_of_day`, `diversity`, `retrieval`.

---

## 7. Explainability

Every item in the `/feed` response carries its own arithmetic:

```json
{
  "post": { "...": "identical to a Supabase feed row" },
  "score": 94.2,
  "signals": [
    { "key": "distance",   "weight": 30, "raw": 0.947, "points": 28.4 },
    { "key": "profession", "weight": 25, "raw": 1.0,   "points": 25.0 },
    { "key": "urgency",    "weight": 18, "raw": 1.0,   "points": 18.0 },
    { "key": "freshness",  "weight": 10, "raw": 0.97,  "points": 9.7  },
    { "key": "trust",      "weight": 5,  "raw": 1.2,   "points": 6.0  },
    { "key": "engagement", "weight": 5,  "raw": 1.0,   "points": 5.0  }
  ]
}
```

`?explain=1` additionally returns raw inputs (`distanceKm`, `hoursOld`, affinity
values, matched profession) and the diversity trace (`movedFrom`, `reason`), plus
a `pools` breakdown showing which retrieval pool contributed each candidate. This
is the tuning instrument — without it, weight changes are guesswork.

---

## 8. Performance & scale

| Concern | Answer |
|---|---|
| N² ranking | Never materialised. Retrieval is 4 index-backed pools with hard limits; scoring is O(candidates × signals) = 400 × 15 ≈ 6 000 float ops. |
| Payload | Hydration touches only the page (20), not the candidate set (400). Heavy joins dropped from 50 rows to 20. |
| Indexes | `(status, archived_at, created_at DESC)` partial; `(category, created_at DESC)` partial; `(latitude, longitude)` partial on live posts; `(is_urgent, urgent_expires_at)` partial; GIN `pg_trgm` on `title`/`description` so search stops being a sequential scan. |
| Round trips per feed | 4: settings (cached 60 s) → affinity (cached 5 min/user) → candidates → hydrate. |
| Caching seam | `FeedSettingsService` and `ViewerContextService` are already the cache boundaries. The documented Redis step is to cache the **scored id list** keyed by `(viewerId, filterHash, timeBucket)`; nothing else has to change. |
| Pagination | `page` + `page_size`, deterministic scoring (time bucketed to 10 min like promotion rotation) so page 2 is consistent with page 1. Cursor-over-score is the Redis-era upgrade. |
| 1 M users | The per-request cost is bounded by `max_candidates`, not by corpus size. Growth moves the *quality* of retrieval, not its cost. |

---

## 9. Future signals — where each one plugs in

| Future signal | Seam that already exists |
|---|---|
| Multi-skill matching | `user_skills` table (live now, empty) |
| Repeat customers / favourite providers | `user_interactions.kind='hire'` → author affinity (already scored) |
| Availability calendar | `users.available_until` becomes a range table; `availability` signal reads it |
| Seasonality / weather | new signal file + `feed_settings` key; no other change |
| Recommendation embeddings | a 5th retrieval pool (`vector` similarity) + one signal reading the same distance |
| AI re-ranking | wraps `scoreCandidates()`; the registry output is already a feature vector |
| Smart provider matching | providers become a 5th candidate type; the signal set applies unchanged |

Nothing above requires the engine to be rewritten. That is the point of the
registry + pool shape.

---

## 10. Test matrix

Unit (pure, no DB) — `backend/src/feed/ranking/*.spec.ts`:

| # | Case | Expectation |
|---|---|---|
| 1 | Nearby user, 1 km vs 20 km, all else equal | 1 km ranks first; `distance` raw ≈ 0.98 vs ≈ 0.39 |
| 2 | Far-away user, 100 km | `distance` raw ≈ 0.06, still non-zero (smooth, no cliff) |
| 3 | Post with no coordinates | raw = 0.5 exactly; never below a distant post with coords |
| 4 | **No location permission** | `distance` returns `null`; excluded from score and from `signals[]`; ordering falls to the other signals |
| 5 | Profession = electrician | Electrical posts outrank equally-fresh Plumbing posts |
| 6 | Wrong / unset profession | `profession` = 0 for all; no crash; ordering unaffected by it |
| 7 | Profession group partial match | 0.55, strictly between exact (1.0) and text-only (0.35) |
| 8 | Multiple skills | best-matching skill wins; primary profession still outweighs a secondary skill |
| 9 | Urgent 0 h / 3 h / 12 h | 1.0 / ~0.75 / ~0.44 — monotonically decreasing |
| 10 | **Urgent expiry** | past `urgent_expires_at` → enum fallback, no urgent boost |
| 11 | Freshness | 24 h old = exactly 0.5 |
| 12 | Engagement crowding | 30 applications scores **below** 8 applications |
| 13 | New provider (0 jobs) | `reliability` = 0.5 neutral, not 0 |
| 14 | Perfect provider (50 jobs, 5.0, no disputes) | `reliability` ≈ 1.0 |
| 15 | Availability on a `request` | `null` (not applicable) |
| 16 | **Anti-spam** | one author with 10 top-scoring posts occupies ≤ 2 slots per page, never 2 in a row |
| 17 | **Category diversity** | never 3 consecutive posts of one category while an alternative exists |
| 18 | Diversity relaxation | a page where every candidate shares one author still returns a full page |
| 19 | Determinism | same input → byte-identical output across 100 runs |
| 20 | Own post | present but demoted below an equivalent foreign post |
| 21 | Already applied | demoted below an equivalent un-applied post |
| 22 | Explainability | `Σ points == score` (within float epsilon) for every item |
| 23 | **Large dataset** | 5 000 candidates × full registry scores in < 150 ms |
| 24 | Empty candidate set | returns `[]`, no throw |
| 25 | All-null signals (anonymous viewer, no location, no profession) | still ranks by freshness/urgency/trust; no NaN, no divide-by-zero |

Manual checklist: [`RECOMMENDATION_ENGINE_TESTING.md`](./RECOMMENDATION_ENGINE_TESTING.md).

---

## 11. File map

**Database** (`supabase/migrations/`)
- `090_feed_settings.sql` — tunable weights + seed
- `091_user_interactions.sql` — behavioural substrate, `fn_user_affinity`, pruning
- `092_post_engagement.sql` — counters + triggers
- `093_users_trust_availability_skills.sql` — `is_verified`, `account_type`, `available_until`, `user_skills`
- `094_feed_indexes.sql` — the indexes ranking actually needs
- `095_fn_feed_candidates.sql` — multi-pool retrieval

**Backend** (`backend/src/feed/`)
- `ranking/` — pure engine, no Nest imports, no I/O, no clock reads:
  `types.ts`, `curves.ts`, `defaults.ts`, `text-index.ts`,
  `signals/*.signal.ts` (one file per signal) + `signals/profession-match.ts`,
  `signal-registry.ts`, `scorer.ts`, `diversity.ts`
- `ranking/signals.spec.ts`, `ranking/scorer.spec.ts`, `ranking/test-fixtures.ts`
  — 78 tests covering the matrix above
- `feed-settings.service.ts`, `viewer-context.service.ts`, `feed.repository.ts`,
  `feed.service.ts`, `feed.controller.ts`, `feed.module.ts`, `dto/feed.dto.ts`

Routes: `GET /feed`, `POST /feed/interactions`, `POST /feed/availability`.

**Mobile** (`mobile-app/lib/`)
- `services/feed_service.dart` — `/feed` client for Discover *and* Jobs, with
  the Supabase fallback
- `services/interaction_tracker.dart` — batched behavioural events
- `providers/app_provider.dart` — ranked load path, request sequencing,
  debounced search, `setViewer()` (replaces the dead `setPriorityLocationCity`)
- tracking call sites: `widgets/post_flows.dart` (open / apply / message),
  `services/saved_service.dart` (save / unsave), `screens/discover_screen.dart`
  (impressions, submitted searches)
