# Recommendation Engine — Manual Testing Checklist

Companion to [`RECOMMENDATION_ENGINE_ARCHITECTURE.md`](./RECOMMENDATION_ENGINE_ARCHITECTURE.md).
The automated matrix (78 tests, `npx jest src/feed`) covers the ranking *maths*.
This covers everything the maths cannot: migrations, wiring, degradation, and
whether the feed actually feels right.

---

## 0. Apply the migrations

Supabase SQL editor, **in order**. Each is additive and re-runnable.

```
090_feed_settings.sql                  -- tunable weights (seeded = compiled defaults)
091_user_interactions.sql              -- behavioural substrate + fn_user_affinity
092_post_engagement.sql                -- counters + triggers + backfill
093_users_trust_availability_skills.sql-- is_verified, account_type, available_until, user_skills
094_feed_indexes.sql                   -- the indexes ranking needs  ⚠️ see note
095_fn_feed_candidates.sql             -- multi-pool retrieval
```

⚠️ **094 takes a SHARE lock on `posts`** for the duration of each `CREATE INDEX`
(writes block). At current volume that is sub-second. On a large table, run each
statement separately from `psql` with `CREATE INDEX CONCURRENTLY` — which cannot
run inside a transaction, and the Supabase SQL editor wraps statements in one.

### Verify each landed

```sql
select key from public.feed_settings order by key;          -- 12 rows
select count(*) from public.post_engagement;                -- == count(*) from posts
select * from public.fn_user_affinity('<your-uid>');         -- runs, returns 0 rows initially
select post_id, category, distance_km, pools
  from public.fn_feed_candidates(
    p_viewer_id => '<your-uid>',
    p_lat => -1.2921, p_lng => 36.8219
  ) limit 10;                                                -- rows with a `pools` column
```

**Nothing above is required for the app to work.** With none of it applied, the
backend falls back to compiled defaults, `fn_feed_candidates` is missing, `/feed`
returns 503, and the app renders its chronological Supabase feed exactly as
before. Confirm that first if you want to see the degradation contract work.

---

## 1. Degradation — do this before anything else

The engine is optional by design. If these three fail, nothing else matters.

- [ ] **Backend down.** Stop the backend. Open Discover. → Feed still loads
      (chronological). No error banner, no empty state, no spinner that never ends.
- [ ] **Backend slow.** Throttle to >8 s. → Feed falls back within ~8 s rather
      than hanging.
- [ ] **`fn_feed_candidates` missing.** Run migrations 090–094 but *not* 095.
      → `/feed` returns 503, app falls back, feed renders.
- [ ] **Airplane mode.** → Cached posts render, offline banner shows, no crash.
- [ ] **Recover.** Bring the backend back, pull to refresh. → Ranked feed returns.

---

## 2. Distance — signal 1

- [ ] Grant location. Post two identical requests, one ~1 km away and one ~50 km
      away, the far one **newer**. → The near one ranks first. *(Under the old
      engine the newer one always won — this single check is the clearest proof
      the ranking is live.)*
- [ ] **Deny location permission entirely.** → Feed still ranks sensibly
      (urgency, freshness, profession). No empty feed, no all-equal ordering.
      `GET /feed?...&explain=1` shows `"distance"` in `debug.skipped`, and the
      `signals` array contains no distance entry.
- [ ] Profile → disable location in-app. → Same as above, immediately, without
      restarting the app.
- [ ] Profile → "Update location" after moving. → Feed re-ranks around the new
      position.
- [ ] A post with **no coordinates** ranks between near and far posts, never
      last by default.

## 3. Profession — signal 2

- [ ] Set your profession to **Electrician**. Refresh Discover. → Electrical
      requests/offers/jobs rise; the feed feels like "there is always electrical
      work here".
- [ ] Switch to **Caterer**. Refresh. → The feed visibly changes. Catering rises,
      electrical falls.
- [ ] Clear the profession (or use an account that never set one). → No crash,
      no empty feed; `explain=1` lists `profession` in `skipped`.
- [ ] A user with a **legacy free-text** profession (pre-086 prose, e.g.
      "electrical works") still gets text-tier matches and no errors.
- [ ] Post a request whose category is *Other* but whose body says
      "fundi wa stima". → An electrician sees it lifted (alias/token tier).

## 4. Skills — signal 3

`user_skills` ships empty; this needs one manual insert.

```sql
insert into public.user_skills (user_id, profession_id, weight)
values ('<your-uid>', 'solar-technician', 0.8);
```

- [ ] Refresh. → Solar-adjacent posts rise, but **less** than posts matching your
      primary profession.
- [ ] Delete the row. → `skills` returns to `skipped`; no other change.

## 5. Urgency — signal 4

- [ ] Post an **urgent ("Right now")** request. → It appears at or near the top
      of a nearby user's Discover feed, not only behind the ⚡ Urgent pill.
- [ ] Wait past `urgent_expires_at` (default 1 h) and refresh. → The boost is
      gone; the post ranks like a normal one. *(Verify with `explain=1`:
      `urgency.detail.windowOpen` flips to `false`.)*
- [ ] Two urgent posts, 10 minutes vs 5 hours old. → The newer ranks higher.

## 6. Freshness, engagement, trust — signals 5, 6, 14

- [ ] A brand-new post from an unknown provider appears in the first page even
      with zero engagement. *(New supply must be discoverable.)*
- [ ] A request with **30 applications** ranks below an equivalent one with 3.
      *(Crowding — the "optimise for matches" rule. Surprising if you have not
      read §3 of the architecture doc; intentional.)*
- [ ] `update public.users set is_verified = true where id = '<uid>'` → that
      provider's offers rise slightly. Set it back → they fall back.
- [ ] A provider with **0 completed jobs** is not buried. `explain=1` shows
      `reliability.raw = 0.5` exactly.

## 7. Availability — signal 7

```
POST /feed/availability  { "user_id": "<uid>", "available": true, "hours": 4 }
```

- [ ] That provider's **offer** posts rise. Their *requests* do not change
      (`availability` is `skipped` on requests — check `explain=1`).
- [ ] `{ "available": false }` → the boost is gone.
- [ ] Set `available_until` to a past timestamp directly in SQL. → No boost.
      *(Stale availability must expire on its own.)*

## 8. Behaviour and search — signals 9, 10

- [ ] Open 5–6 **Plumbing** posts. Wait ~10 s (the batch flush) then pull to
      refresh. → More plumbing near the top.
- [ ] Confirm the events landed:
      `select kind, category, created_at from public.user_interactions where user_id = '<uid>' order by id desc limit 20;`
- [ ] **Type** "electrician" in the search box without submitting. → Exactly ONE
      network call after you stop typing (not eleven), and **no** `search` row in
      `user_interactions`.
- [ ] **Submit** the search (keyboard ↵). → A `search` row appears; the feed
      reloads immediately.
- [ ] Clear the search. → Recent-query influence persists for a while, then
      decays (48 h half-life, 7-day window).
- [ ] Sign out and back in as a different account. → **No** cross-account
      personalisation. The new account's feed reflects only its own history.

## 9. Diversity and anti-spam — signals 12, 13

- [ ] Post **8 offers from one account** in quick succession. Browse from a
      different nearby account. → That author occupies at most **2** slots per
      page and never two in a row.
- [ ] Ensure many same-category posts exist. → Never 3 consecutive cards of one
      category while an alternative exists.
- [ ] A thin feed (fewer than 10 posts total) still shows **every** post — the
      constraints degrade, they never truncate.

## 10. Own posts, applied posts, filters

- [ ] Your own listing appears in Discover but **below** comparable posts by
      others. It is never hidden.
- [ ] Apply to a request, refresh. → It drops down the feed but stays reachable
      with its "Applied" state intact.
- [ ] Filter to a single category. → **Only** that category appears. Ranking
      never overrides an explicit filter.
- [ ] Set a price range. → Respected. A post priced 0 ("negotiable") is no longer
      hidden when the minimum is above zero *(the audit §3.5 bug)*.
- [ ] Requests / Offers tabs each show only their type. Jobs never leak into
      Discover.
- [ ] Closed listings (`assigned` / `completed` / `cancelled`) **no longer
      appear** in the feed at all *(audit §3.6)*.

## 11. Sponsored content — signal 15 (regression only)

Nothing here changed; confirm nothing broke.

- [ ] First sponsored card appears after 7 organic cards, then every 8.
- [ ] Sponsored cards never cluster and never duplicate an organic post.
- [ ] A feed of fewer than 7 posts shows **no** sponsored card.
- [ ] Impressions and clicks still record in `promotion_events`.

## 12. Jobs tab

- [ ] Jobs are ranked, not chronological — with a profession set, matching jobs
      rise.
- [ ] Search and the employment-type filter still work.
- [ ] With the backend down, Jobs falls back to the old chronological list.

## 13. Explainability

```
GET /feed?user_id=<uid>&lat=-1.2921&lng=36.8219&explain=1
```

- [ ] Every item carries `score` and a `signals` array.
- [ ] `Σ signals[].points == score` for each item (±0.1 rounding).
- [ ] `debug.pools` shows which retrieval pools found each candidate
      (`nearby,affinity,fresh`).
- [ ] `debug.skipped` lists exactly the signals with no data for that viewer.
- [ ] Items moved by the composition pass carry
      `debug.diversity: { movedFrom, reason }`.

## 14. Tuning without a deploy

- [ ] `update public.feed_settings set value = jsonb_set(value, '{distance}', '60') where key = 'weights';`
- [ ] Wait 60 s (settings cache TTL), refresh. → Distance visibly dominates.
- [ ] Restore. → Behaviour returns. **No deploy, no app release.**
- [ ] Write a deliberately invalid value
      (`'{"distance": "not a number"}'`). → The engine keeps the compiled
      default and logs a warning. **The feed does not break.**

## 15. Performance

- [ ] `GET /feed` `took_ms` is < 500 ms warm on a normal-sized corpus.
- [ ] `candidate_count` is ≤ `retrieval.maxCandidates` (400).
- [ ] Scrolling to page 2 returns **no duplicates** from page 1.
- [ ] `explain analyze` the candidate function and confirm the partial indexes
      from 094 are used (look for `Index Scan using idx_posts_feed_*`, not
      `Seq Scan on posts`):
      ```sql
      explain analyze
      select * from public.fn_feed_candidates(p_lat => -1.2921, p_lng => 36.8219);
      ```

---

## Known issues this work did NOT change

Recorded so they are not mistaken for regressions.

1. **`posts.urgent_expires_at` is a naked `TIMESTAMP` written from LOCAL time.**
   `PostService.createPost` writes `DateTime.now().add(1h).toIso8601String()`
   (no offset, so Nairobi local), while `fetchUrgentPosts` compares against
   `DateTime.now().toUtc()`. In UTC+3 that makes urgent posts behave as though
   they last ~4 hours rather than 1. `fn_feed_candidates` reproduces the existing
   comparison exactly (`NOW() AT TIME ZONE 'UTC'`) so the ranked feed and the ⚡
   Urgent pill agree rather than disagreeing. The urgency signal decays from
   `created_at` (a reliable `TIMESTAMPTZ`), so ordering is unaffected either way.
   **Fixing this is a separate, behaviour-changing task.**

2. **Feed rows are still heavy.** Hydration uses the app's existing select,
   including `applications(*, users!applicant_user_id(...))`, because
   `PostCard` renders `post.applications.length`. This is now paid for 20 rows
   per page instead of 50, but the right fix is a count instead of the full
   applicant list.

3. **Provider discovery still does not exist** (audit §3.14). Providers are
   reachable only through a post or an applicant card. The engine's signal set
   applies unchanged the day a provider surface is added — providers become a
   fifth candidate type.

4. **`view_count` lags.** The engagement trigger fires on `open` and `message`,
   not on `impression`, so impression-only posts carry a stale view count.
   Harmless: raw views contribute **zero** to the engagement score by design.
