# Feed Stability & Location Accuracy

**Companion to:** [`RECOMMENDATION_ENGINE_ARCHITECTURE.md`](./RECOMMENDATION_ENGINE_ARCHITECTURE.md)
**Status:** implemented — see §6 for the file map.

> The recommendation engine was correct and felt unreliable. This is the work
> that closed the gap between the two. Nothing here changes how a post is
> scored; it changes **when ranking runs and what it is allowed to do to a
> screen someone is already reading.**

---

## 1. Issue 1 — the feed reshuffled while people read it

### Root cause

Not one bug. Ranking was simply not treated as something that finishes. The post
list was a mutable field that four independent callers replaced, and every
replacement re-sorted the cards under the reader's thumb.

| # | Where | What the user saw |
|---|---|---|
| 1 | `app_provider.dart` — the splash prefetch painted a chronological page, then `unawaited(Future.microtask(loadPosts))` immediately re-ranked it | A full reorder ~1 s after Discover appeared. **Every cold start.** |
| 2 | The restored Firebase session resolved *after* that first paint, and `setViewer` reloaded again | A second reorder, ~1 s later still |
| 3 | `setViewer` tested `latitude != _viewerLatitude` — a raw double comparison against a value the fused provider revises by metres | Any GPS revision cost a full Discover **and** Jobs reload. Standing still was enough to make the feed churn |
| 4 | `feed.service.ts` scored against `new Date()`; `rotationBucketMinutes` was declared in config, seeded into `feed_settings`, documented as the determinism mechanism — and read by nothing | Two requests seconds apart legitimately disagreed about near-tied posts |
| 5 | `ingestInteractions` invalidated the 5-minute viewer cache on **every** batch, including impression-only ones | Scrolling invalidated the cache every ~8 s, so every rebuild came back subtly different |

Causes 1–3 are the visible reshuffle. Causes 4–5 are why any rebuild — however
well-timed — could not be trusted to return the same answer twice.

### The fix: a snapshot

Ranking is computed **off-screen** and frozen with the conditions it was computed
under. `services/feed_snapshot.dart`:

```
FeedSnapshot   posts (unmodifiable) · source · identity · generatedAt
               rankingEpoch · scores · signals · personalised

FeedIdentity   userId · latitude/longitude · profileRevision · queryKey · version
```

`AppProvider` holds two of them: `_installed` (what is on screen) and `_pending`
(a newer ranking that has been computed and is **waiting for permission**).

### When a rebuild may move the screen

`FeedInvalidation.replacesVisibleFeed` is the whole policy, and it is pinned by a
test that enumerates every enum value:

| Reason | Trigger | Behaviour |
|---|---|---|
| `explicit` | pull-to-refresh, Retry, the prompt itself | **Replace** |
| `viewer` | sign-in / sign-out | **Replace** — the feed belongs to someone else now |
| `query` | tab, filters, search | **Replace** — the visible list answers a question nobody is asking |
| `version` | a release changed what ranking means | **Replace** |
| `location` | moved ≥ 1 km | Offer |
| `profile` | profession / profile edited | Offer |
| `authored` | user published a listing | Offer |
| `expired` | snapshot older than 10 min | Offer |

Three additional install paths exist, and each one makes the swap *unseeable*
rather than permitted:

1. **Nothing is installed yet** — first paint, nothing to disturb.
2. **Discover is not the visible tab** — `HomeScreen` reports visibility, and a
   ranking that lands while the user is in Messages is simply installed. This is
   most of what "the user should hardly see the rebuild" means in practice.
3. **The new ranking does not visibly differ** — compares the first 10 ids. This
   is what keeps the prompt honest: most background rebuilds return the same
   order, and a "New recommendations" pill that reorders nothing teaches people
   to ignore it.

One deliberate exception: **gaining coordinates for the first time replaces.**
The distance signal goes from not participating at all to carrying the heaviest
weight in the model — that is a different feed, not a rearrangement of this one.

### Rank before first paint

The splash prefetch is no longer painted. It is passed into `FeedService.fetchFeed`
as `warmFallback` — the degradation source — so it still saves a round trip on
the one path that needs it (a backend too cold to rank) without ever showing a
chronological page that a ranked one then replaces.

The first ranking also **waits for the viewer to be known** (`_viewerGrace`,
900 ms), so a restored session is ranked for the right person the first time
rather than anonymously-then-again. If no identity arrives, it proceeds without
one — the grace period is a wait, not a dependency.

### The server half

`bucketInstant(now, rotationBucketMinutes)` in `ranking/curves.ts`. Every
time-dependent signal now reads a **floored 10-minute epoch** instead of a wall
clock, so a feed asked for twice inside one bucket is byte-identical. Floored,
never rounded: a rounded bucket can sit in the future and would expire an urgent
post before its deadline.

The epoch is returned as `ranking_epoch` so the client can tell "the feed moved
on" from "the clock ticked".

Impression-only interaction batches no longer invalidate the viewer cache. An
impression weighs 0.05 and arrives continuously; it cannot move affinity enough
to change an ordering, and invalidating on it defeated the cache entirely.

---

## 2. Issue 2 — "user is in Kisauni, Help24 stores Nyali"

### Root cause

Three independent causes, and only one of them was about GPS.

#### 2a. The dataset made the right answer unreachable

`mombasa-kisauni` was in the registry **with no coordinate** — as were 123 of the
133 neighbourhoods in the country. `LocationRegistry.nearest()` only considers
entries that have one, so a fix taken in Kisauni could never snap to Kisauni: the
nearest coordinate-bearing place was **Nyali, 2.4 km away**. The app was
structurally incapable of returning the right answer.

The same defect had a second, quieter effect: `selectionFor()` gives a
coordinate-less neighbourhood its **parent city's centre**, so a post placed in
Kisauni was stored at Mombasa Island — a ~5 km lie in the one field the distance
signal actually reads.

`test/location_accuracy_test.dart` reproduces the pre-fix dataset and asserts it
returned Nyali, so the regression cannot be re-introduced silently.

#### 2b. The naming ladder never checked the map

`describe()` accepted a geocoder answer purely because the registry recognised
the **name**, with no test that the named place was anywhere near the fix.
Android's `subLocality` on the Mombasa mainland is a coarse polygon that reports
"Nyali" well outside Nyali.

It also read `subLocality` in preference to `subAdministrativeArea` — which in
Kenya is usually the **sub-county / constituency**, i.e. exactly the level people
name ("Kisauni", "Changamwe", "Likoni"). The precise answer was already in the
response, unread. `county` was computed and dropped on the floor.

#### 2c. Accuracy and staleness were never looked at

`Geolocator.getCurrentPosition` returns the **first** location the platform
offers. On Android that is routinely a cached or network-derived fix with an
accuracy radius of 1–3 km — a circle spanning several of these neighbourhoods.
Nothing in the app read `Position.accuracy` or `Position.timestamp`, so a 2 km
guess and a 5 m satellite fix were treated identically and whichever arrived
first won.

And `_lastUpdated` was written on every capture and **read by nothing**. A
position captured once was reused indefinitely. A user who enabled location in
Nyali last month was still being ranked from Nyali today — which is the plainest
possible reading of the report, and no amount of GPS accuracy fixes it.

### The fix

| Cause | Fix |
|---|---|
| 2a | 123 neighbourhood coordinates added to `assets/data/locations_ke.json`; `088_locations_registry.sql` regenerated from it; dataset version 1 → 2 so devices refresh. A test asserts **every** neighbourhood carries one, plus bounds, parent proximity and uniqueness checks |
| 2b | `describe()` walks names **most-specific-first** (ward → area → sub-county → locality → city → county) and checks each against the map. Neighbourhood plausibility is **comparative**, not a fixed radius — see below |
| 2c | `LocationService.getPreciseFix()` listens instead of asking: `LocationAccuracy.best`, keeps the best fix, discards stale (> 45 s) and mocked ones, returns at ≤ 50 m, settles at ≤ 150 m after 12 s, and **fails** rather than store anything coarser. `LocationProvider.refreshIfStale()` re-reads only past a 20-minute threshold |

#### Why plausibility has to be comparative

Kisauni and Nyali are 2.4 km apart — closer than some single estates are wide. No
absolute threshold can both accept a large estate and reject the one next door.
The question that works is *"is anything nearer?"*:

> A geocoded **neighbourhood** is believed only if it is at least as close to the
> fix as the nearest place we know about, ± 1 km. Within a kilometre of a tie the
> answer is genuinely ambiguous and the geocoder — which has polygons — is the
> better authority.
>
> A **city or town** is judged absolutely (25 km), because a city legitimately
> extends far beyond its centroid and a nearer neighbourhood says nothing about
> whether the city name is right.

#### Why a coarse fix is a failure, not a fallback

A missing viewer location makes the distance signal return `null` — "not
applicable" — and the feed ranks honestly on everything else. A *wrong* location
silently mis-ranks every post while looking exactly like a working app. Refusing
the fix is the safer failure, and the user keeps the manual town picker either
way.

### What is stored now

`LocationSelection` carries `county`, `subCounty`, `ward`, `locality`,
`formattedAddress` and `accuracyMeters` alongside the coordinates, persisted as
one JSON record per user (the legacy scalar keys are still written, and still
read as a migration path).

**Distance is never computed from any of it.** Proximity is latitude/longitude
through `utils/proximity.dart` on the client and the haversine in
`fn_feed_candidates` on the server. The names exist so a location can be
displayed, filtered and *audited* — "what did we think this was?" is now
answerable instead of being guessed at from one label string.

### Job posts

Jobs were created with a location **label and nothing else**, even though
`JobModel` has carried `latitude`/`longitude` all along. The Jobs tab runs
through the same engine as Discover, where distance is the heaviest signal — so
every job in the country was scored at "the median distance of everything else"
rather than at its own. A job across the road and a job in another county ranked
identically on proximity. They now use the same coordinate precedence as requests
and offers: the map pin, else the chosen place's coordinate.

---

## 3. Battery

There is no timer, no position stream, and no polling anywhere in this work.

* `getPreciseFix` opens a stream for **at most 12 s** and always cancels it,
  including on the early-success path.
* `refreshIfStale` runs on app resume, does nothing at all unless the stored
  position is older than 20 minutes, and costs one bounded burst when it does.
* A refresh that lands within 1 km of where we already were reports *no
  movement*, so it never triggers a feed rebuild.

---

## 4. Contracts that must not be broken

1. **Nothing on screen moves unless the person looking at it asked.** The four
   `replacesVisibleFeed` reasons are the complete list, and
   `test/feed_stability_test.dart` fails if a fifth appears without a decision.
2. **Ranking never reads a free-running clock.** Every time-dependent signal
   reads the bucketed epoch. Reintroducing `new Date()` in a signal reintroduces
   the reshuffle.
3. **A coordinate is never stored unless it was measured well enough to trust.**
   150 m is the ceiling. Loosening it is a two-file edit on purpose — see the
   duplicated constants in `test/location_accuracy_test.dart`.
4. **Every neighbourhood in the registry carries a coordinate.** One without is
   invisible to snapping *and* silently inherits its city's centre. Adding a
   place without a position fails the test suite.
5. **Distance is geometry.** Never compare `"Mombasa"` against `"Kisauni"`.

---

## 5. Remaining data debt

263 of the 479 registry entries — all rural **towns**, no neighbourhoods — still
ship without coordinates. This is pre-existing and much less harmful: a town
without a position is merely excluded from snapping (the safe behaviour the
dataset was designed around), whereas a *neighbourhood* without one actively
produced a wrong answer. Filling them is a data task, not a code change.

---

## 6. File map

**Backend** (`backend/src/feed/`)
- `ranking/curves.ts` — `bucketInstant()`
- `feed.service.ts` — epoch threaded into `ViewerContext`; `ranking_epoch` in the
  response; impression-only batches no longer invalidate the viewer cache
- `ranking/regressions.spec.ts` — 6 new tests pinning clock determinism

**Mobile** (`mobile-app/lib/`)
- `services/feed_snapshot.dart` — **new.** `FeedSnapshot`, `FeedIdentity`,
  `FeedInvalidation`
- `providers/app_provider.dart` — snapshot-backed feed, staged rebuilds,
  `maybeRefreshFeed`, `markProfileChanged`, significance-gated `setViewer`
- `services/feed_service.dart` — `warmFallback`, `rankingEpoch`
- `screens/discover_screen.dart` — the "New recommendations" prompt, floating so
  it cannot push the feed down
- `screens/home_screen.dart` — tab-visibility signal, resume refresh
- `services/location_service.dart` — `getPreciseFix()`, full reverse-geocode
  parsing, best-placemark selection
- `services/current_location_service.dart` — precise fix, `lowAccuracy` failure,
  specificity-ordered and map-checked naming ladder
- `providers/location_provider.dart` — full record persistence, `isStale`,
  `refreshIfStale`
- `models/place.dart` — administrative fields + accuracy on `LocationSelection`
- `screens/post_screen.dart` — coordinates on job posts; prefill from the stored
  record
- `screens/place_picker_screen.dart`, `widgets/location_picker.dart`,
  `widgets/profile_editors.dart` — call-site updates

**Data**
- `mobile-app/assets/data/locations_ke.json` — 123 coordinates, version 2
- `supabase/migrations/088_locations_registry.sql` — regenerated by
  `scripts/build_reference_seed.js`. **Never hand-edited**

**Tests**
- `mobile-app/test/feed_stability_test.dart` — **new**, 33 tests
- `mobile-app/test/location_accuracy_test.dart` — **new**, 25 tests
- `mobile-app/test/reference_registry_test.dart` — updated: a neighbourhood now
  posts with its own coordinate; the city-inheritance fallback is still pinned
