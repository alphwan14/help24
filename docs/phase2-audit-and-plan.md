# Phase 2 — Audit, Plan, and 2A Implementation

Status: **Phase 2A COMPLETE — deployed and verified in production.**
2B–2E remain planned only; nothing from them is implemented.

| | |
|---|---|
| **Commit** | `964c980` — *feat(feed): admin API for ranking configuration (Phase 2A)* |
| **Deploy** | `dep-d9r1k237uimc73cb757g` |
| **Live at** | 2026-08-07 **17:47:51 UTC** |
| **Migrations applied** | **none** |
| **Render configuration changed** | **none** |
| **Flutter changes** | **none** |
| **Route census** | 108 → **111** (firebase 39 → 39, admin 46 → **49**, public 23 → **23**) |
| **Tests** | 543 → **568** passing |

This audit is grounded in what production actually showed during Priority 1 and
Stage 1, not in a fresh read of the source. Where a claim is measured, the
measurement is quoted.

---

## 0. What production changed about the plan

Three observations reorder the roadmap the earlier audit proposed.

**0.1 `feed_settings` is already live and already populated — but unwritable.**

```
feed_settings : 13 rows — availability, behaviour, distance, diversity,
                engagement, freshness, reliability, retrieval, staleness,
                time_of_day, trust, urgency, weights
promotion_settings : 3 rows — moderation, payment, serving
app_settings       : 6 rows — the Phase 0/1 client contract
```

Promotion settings have an admin API. The client config plane has one. **Ranking
— the thing tuned most often — has none.** Retuning Discover today means
hand-written SQL against a production table: no key validation, no audit line,
and no way back to the previous value once overwritten. That is the single
highest-ROI, lowest-risk item in the whole of Phase 2, and it needs no
migration, no schema change and no Flutter release. It is 2A.

**0.2 There is no traffic to A/B against.** No payments since 2026-06-22; the
most recent user notification is 2026-07-27; every `WOULD_DENY` in the log
window is my own `curl`. Any Phase 2 item whose value is "lets us experiment
with live cohorts" is worth **less** today than an item that reduces the cost of
an operator action. This demotes experiment/rollout plumbing and promotes
tuning surfaces and diagnostics.

**0.3 The client already has a working three-stage config contract.** Compiled
defaults → SharedPreferences cache → async refresh, with a 15-minute TTL and
ETag/304. Adding a key to `ClientConfig` is now genuinely cheap and carries its
own offline story. The expensive part of a client-side migration is no longer
the plumbing — it is the Flutter release needed to *read* the new key, which is
why every client item below is 2E regardless of how small it looks.

---

## 1. Method

Every `static const`, `Duration(...)` literal and module-level constant in
`mobile-app/lib` (63,663 lines) and `backend/src` was enumerated, then each was
asked four questions:

1. Would changing it require an APK?
2. Would anyone ever actually change it?
3. Does moving it weaken security, offline behaviour, or determinism?
4. Does it fail safe when the backend is unreachable?

A value earns migration only on **yes / yes / no / yes**. Question 2 eliminated
more candidates than any other — most constants are not operational levers, they
are decisions that were made once and are correct.

---

## 2. Phase 2A — implemented

### 2A-1 · Ranking admin API `/admin/feed/settings` ★ highest ROI

| | |
|---|---|
| **Current location** | `feed_settings` table, readable via `FeedSettingsService`, writable only by raw SQL |
| **Why it exists there** | The reader shipped with migration 090; the write surface was never built |
| **Operational impact** | Ranking is retuned continuously. Every tuning cycle currently requires a human writing SQL against production |
| **Risk** | Low. Additive routes only. The reader's per-key type guard is unchanged and still discards wrong-typed values |
| **Offline implications** | None — server-side only |
| **Security implications** | Reduces exposure. Replaces unaudited console SQL with a role-gated, logged, key-validated surface |
| **Destination** | `FeedSettingsAdminController` |
| **Migration strategy** | None required — the table exists and is populated |
| **Rollback** | Remove the controller from `FeedModule`; or `DELETE` any key to restore the compiled default |
| **Operational value** | **Very high** |

**What was built** (`backend/src/feed/feed-settings-admin.controller.ts`):

```
GET    /admin/feed/settings        support_agent  effective + stored + defaults
PATCH  /admin/feed/settings/:key   senior_admin   replace one document
DELETE /admin/feed/settings/:key   senior_admin   restore the compiled default
```

Three design decisions worth stating:

- **`GET` returns effective, stored and defaults together.** The merged document
  alone cannot tell you whether `weights.distance = 30` is pinned in the table
  or is the default showing through — and that is exactly what someone about to
  retune needs to know. `overridden_keys` makes it explicit.
- **`DELETE` is the point, not a convenience.** Reverting a bad hand-written
  edit today requires knowing what the value was *before* it was overwritten.
  With `DELETE`, revert is one call, and the value it reverts to is the one the
  ranking regression suite already asserts.
- **No range validation, deliberately.** A weight of 30 and a weight of 3000 are
  both numbers; inventing "sensible" bounds here would be policy the regression
  suite expresses better. The mitigation for a bad value is `DELETE`.

**Tests:** 19 new in `feed-settings-admin.spec.ts` — key allowlist (including
`time_of_day`, the one key whose table name differs from its config field),
non-object bodies, per-entry merge, wrong-typed values falling back to default,
cache invalidation, and reset. Suite **562 passing**, up from 543. `tsc` clean.

**The boot check earned its place.** Every unit test passed while the
application could not start: `FeedModule` imports nothing, so `AdminAuthGuard`
could not resolve `AdminAuthService`. Unit tests construct the controller
directly and never touch the injector, so **only actually booting the app caught
it**. Fixed by importing `AdminAuthModule` (the narrow module that exists
precisely to be imported by feature modules needing the guard).

Verified boot under `AUTH_ENFORCEMENT=enforce`:

```
111 routes — firebase=39 admin=49 public=23 undeclared=0 (mode=enforce)
Mapped {/admin/feed/settings, GET}
Mapped {/admin/feed/settings/:key, PATCH}
Mapped {/admin/feed/settings/:key, DELETE}
Nest application successfully started
```

108 → 111 routes, admin 46 → 49, `undeclared=0`. The route audit that refuses to
start on a declaration mismatch accepts the new surface.

---

## 3. Phase 2B — high value, backend-only, no new tables

| # | Item | Current location | Why it matters | Value | Risk |
|---|---|---|---|---|---|
| 2B-1 | **Build identifier on `/health`** | absent | I could not prove which commit was live without the Render API. `RENDER_GIT_COMMIT` is already in the environment | High | Very low |
| 2B-2 | **Event retry budget** — `MAX_RETRIES=3`, `RETRY_INTERVAL_MS=60_000` | `event-processor.service.ts:10-11` | The dead-letter incident turned on exactly these. Tuning them during an incident currently needs a deploy | High | Low |
| 2B-3 | **Dead-letter replay window** — `now-24h` | `events.service.ts:139` | **Discovered today:** any event not replayed within 24 h becomes permanently unreachable to automation. Currently invisible and unconfigurable | High | Low |
| 2B-4 | **Dispute SLA** — `AUTO_ESCALATE_AFTER_DAYS=3`, `SWEEP_INTERVAL_MS=30 min` | `sla.service.ts:15-16` | Pure policy. Changing an SLA should not be a release | Medium | Low |
| 2B-5 | **Dispute rate limit** — 5 per 24 h | `disputes.service.ts:25-26` | Abuse control that needs tuning against real abuse | Medium | Low |
| 2B-6 | **Promotion payment TTL** — 24 h | already in `promotion_settings.payment` | Already configurable; only needs surfacing in admin UI | Low | None |
| 2B-7 | **Viewer/registry cache TTLs** — 10 min / 5 min / 5000 entries | `viewer-context.service.ts:23-26` | Memory-vs-freshness lever on a free-tier instance | Medium | Low |

2B-3 deserves emphasis. It is not a tuning knob — it is a **silent trap**. An
event that dead-letters and is not noticed within 24 hours can never be replayed
except through the admin endpoint, and there is no runbook for that endpoint. I
would fix the observability before the configurability: surface the age of the
oldest dead-lettered event in `/health/events`.

## 4. Phase 2C — requires API additions

| # | Item | Note |
|---|---|---|
| 2C-1 | Notification timing/batching | Server-side send policy; needs a settings document and an admin surface |
| 2C-2 | Search ranking configuration | `retrieval` is already a `feed_settings` key; search-specific weights are not separated from feed weights yet |
| 2C-3 | Profession-match weights | Already inside `feed_settings.weights.profession` as a single scalar. Per-profession weighting needs a new document shape |
| 2C-4 | Promotion quality coefficients | `serving-logic.ts` holds placement rules; quality scoring is not yet parameterised |

## 5. Phase 2D — requires database additions

| # | Item | Note |
|---|---|---|
| 2D-1 | Fee schedule / payout timing | **Financial.** Must be versioned and effective-dated, never a mutable row — a fee change must never retroactively alter historical settlements |
| 2D-2 | Escrow cleanup sweep | Designed already in `escrow-cleanup-design.md`; needs the `escrow_abandoned` audit table |
| 2D-3 | Fraud / spam / moderation thresholds | No abuse signal store exists yet; thresholds without measurement are guesses |
| 2D-4 | Experiment / cohort assignment | Deferred: **no traffic to experiment on** (§0.2) |

## 6. Phase 2E — requires Flutter changes

Every item here needs an APK to *read* the new key, which is precisely the cost
Phase 2 exists to avoid. Each is therefore worth doing **once**, batched into a
single release, rather than one at a time.

| # | Item | Current location | Value |
|---|---|---|---|
| 2E-1 | Telemetry batching — `_flushAt=10`, `_flushAfter=8s`, `_maxQueue=200` | `interaction_tracker.dart:42-47`, `promotion_tracker.dart:18-19` | High — direct battery/data lever |
| 2E-2 | HTTP timeouts — 30 s default, 90 s storage, 8 s feed | `http_client_with_token.dart:29,34`, `api_client.dart:57`, `feed_service.dart:110`, `jobs_service.dart:49` | High — the only lever when a network is slow |
| 2E-3 | Connectivity backoff — `[10,30,60,120,300]`, probe 5 s, 2 failures | `connectivity_provider.dart:120-123` | Medium |
| 2E-4 | Feed snapshot TTL — 10 min; `significantMoveKm=1.0` | `feed_snapshot.dart:141,464`, `location_provider.dart:43` | Medium — governs refresh frequency |
| 2E-5 | Location freshness window — 20 min | `location_provider.dart:38` | Medium |
| 2E-6 | Notification page size 30; cache cap 60 | `notification_store.dart:115`, `cache_service.dart:191` | Low |
| 2E-7 | OTP resend backoff `[30,60,120]`; email cooldown 30 s | `auth_screen.dart:609`, `email_verification_banner.dart:51` | Low — and see §7 |
| 2E-8 | Bio max length 300 | `profile_editors.dart:486` | Low |

---

## 7. Never migrate — and why

| Item | Location | Reason |
|---|---|---|
| Supabase anon key, Firebase API keys | `supabase_config.dart:10`, `firebase_options.dart` | Client credentials. Serving them would let an unauthenticated `/config` call harvest them |
| `minPasswordLength = 8` | `auth_service.dart:984` | A remotely-lowerable password floor is a remotely-triggerable account-takeover surface. The upside is nil |
| OTP resend backoff | `auth_screen.dart:609` | Listed as 2E-7 at **low** priority precisely because it is a brute-force control. If migrated it must be floor-clamped client-side so the server can only make it *stricter* |
| Auth timeouts (30 s) | `auth_service.dart:171` | Sits on the credential path; a remotely-extendable auth timeout widens a race window |
| Distance maths — `_earthRadiusKm = 6371.0` | `proximity.dart:15` | Physics, not policy |
| Card/layout tokens | `feed_card_tokens.dart` | Design system. Remote UI is explicitly out of scope |
| Splash/fade durations | `main.dart:706`, `launch_splash.dart` | Inside the launch transaction; a remote value cannot be read before the config it would gate |
| `feedVersion = 1` | `feed_snapshot.dart:454` | Cache-schema discriminator. Remote control would let a bad value orphan every client's cache |
| Deep-link domains, package name | `app_urls.dart`, `auth_service.dart:432` | Must match the signed manifest and Firebase authorized domains |

**The launch-transaction rule generalises.** Anything read *before* the first
successful `/config` fetch cannot be remotely configured without breaking cold
start. That rules out splash timing, the config TTL itself, and the base URL.

---

## 8. ROI ranking

| Rank | Item | Phase | Value | Risk | Needs APK |
|---|---|---|---|---|---|
| 1 | Ranking admin API | **2A ✅** | Very high | Very low | No |
| 2 | Dead-letter age visibility + window | 2B-3 | High | Low | No |
| 3 | Build identifier on `/health` | 2B-1 | High | Very low | No |
| 4 | Event retry budget | 2B-2 | High | Low | No |
| 5 | Telemetry batching | 2E-1 | High | Low | **Yes** |
| 6 | HTTP timeouts | 2E-2 | High | Medium | **Yes** |
| 7 | Dispute SLA + rate limit | 2B-4/5 | Medium | Low | No |
| 8 | Viewer cache TTLs | 2B-7 | Medium | Low | No |
| 9 | Feed snapshot TTL / move threshold | 2E-4 | Medium | Medium | **Yes** |
| 10 | Fee schedule | 2D-1 | High | **High** | No |

Items 2–4 and 7–8 are all backend-only and could ship as one small release.
Items 5, 6 and 9 should be batched into a single Flutter release.

Fee schedule is ranked last despite high value because it is the one item where
a configuration mistake moves money. It needs effective-dating, not a mutable
row, and belongs after everything above has proven the pattern.

---

## 9. Rollout, rollback, and what to watch

**2A rollout.** Merge → deploy. No migration, no client change, no env change.
The routes are inert until an admin calls them; behaviour before the first
`PATCH` is byte-identical to today, because the reader is unchanged and the
table already holds the same 13 rows.

**2A rollback.** Three independent levers, cheapest first:
1. `DELETE /admin/feed/settings/:key` — restores the compiled default for that
   key, no deploy.
2. Direct SQL — the previous path, still available.
3. Remove `FeedSettingsAdminController` from `FeedModule` and redeploy.

**Monitor after rollout:**
- `[FEED][SETTINGS] '<key>' replaced by admin` / `reset to compiled default` —
  every write is logged with the key.
- Feed p95 latency — the settings cache is 60 s, so a write costs at most one
  extra query per instance per minute.
- Discover CTR / application rate — the actual point of retuning. Note §0.2:
  with current traffic these will be too sparse to read quickly.
- 400 rate on `/admin/feed/settings/*` — a spike means the key allowlist is
  rejecting something an operator expects to work.

**Benchmark:** not warranted. The change adds no work to the read path; `GET`
performs one extra `select` against a 13-row table, on an admin-only route.

---

## 9b. Phase 2A — production verification record

Deployed `964c980` as `dep-d9r1k237uimc73cb757g`, live **2026-08-07 17:47:51 UTC**.

### Boot

```
[AUTH][ROUTES] 111 routes — firebase=39 admin=49 public=23 undeclared=0 (mode=enforce)
Mapped {/admin/feed/settings, GET}
Mapped {/admin/feed/settings/:key, PATCH}
Mapped {/admin/feed/settings/:key, DELETE}
Nest application successfully started
```

**Zero DI errors.** The only boot WARNs are the two pre-existing self-reporting
banners (`REDIS_URL` unset; authentication partially enforced under
`AUTH_ENFORCE_ONLY=/promotions`) — both identical to the previous deploy.

### Verified in production

| Check | Result |
|---|---|
| Deployment completed | `live`, commit `964c980` |
| Backend health | database **healthy** 53 ms · firebase **healthy** 50 ms · redis degraded (pre-existing) |
| New routes registered **and guarded** | `GET`/`PATCH`/`DELETE` all return 401 *"Missing admin bearer token"* |
| Control — a genuinely absent route | 404, confirming 401 above means "registered", not "missing" |
| Deactivated bootstrap token refused | 401 *"This admin account is inactive"* |
| Public route count | 23 → 23 — **no new public surface exposes configuration** |
| `/config` ETag behaviour | `W/"3b6c0888a44bf4c1"`, conditional request → **304**, unchanged |
| Anonymous feed | 200, 5 items, ranking fingerprint `cd53550e3f9d65c4` |
| `/health`, `/promotions/packages`, `/reputation/health` | 200 |
| Auth Stage 1 still holding | `/promotions/campaigns` anonymous → **401** |
| `feed_settings` | 13 rows, fingerprint `6d886892465d1f1fd95084c9d82bfc8f`, **no writes** |
| Escrow | fingerprint `351c0047cd783dd30bfc8fdea0bf262a`, unchanged |
| Unexpected 4xx / 5xx | none — the only 4xx are my own probes |

`GET /admin/feed/settings/weights` returns 404 **by design**: `GET` is defined on
the collection, `PATCH`/`DELETE` on `:key`. The control probe confirms the
distinction.

### Still outstanding

**The authenticated round trip — `PATCH` a value, confirm it changed, `DELETE`
it, confirm the compiled default returns — has NOT been run against
production.** Admin tokens are stored as SHA-256 hashes and cannot be recovered,
and minting one is a production credential mutation with no approval behind it.
The behaviour is covered by 25 unit tests including the merge, idempotency,
concurrency and reset paths, and the HTTP guard layer is proven separately by
the 401 probes — but the end-to-end round trip needs an admin bearer token.

### Rollback

Three levers, cheapest first, none requiring a migration:

1. **`DELETE /admin/feed/settings/:key`** — restores the compiled default for
   that key. No deploy, seconds.
2. **Direct SQL** on `feed_settings` — the pre-existing path, still available.
3. **Revert `964c980`** and redeploy — removes the three routes entirely. The
   reader is untouched by this commit, so ranking is unaffected either way.

### Operational impact

Retuning Discover no longer requires hand-written SQL against production. The
write path now validates the document key *and* the field names, merges instead
of replacing, guards against concurrent edits, logs every change, and can be
reverted in one call. Before activation — and until an admin issues a `PATCH` —
behaviour is byte-identical to before: the reader is unchanged and the table
still holds the same 13 rows.

### Lessons learned

1. **Green tests proved nothing about whether the app could start.** All 19
   original tests passed while `FeedModule` could not resolve `AdminAuthGuard`.
   Unit tests construct controllers directly and never touch the Nest injector.
   The boot check is not ceremony — it is the only thing that exercises DI.
2. **I wrote the fix comment before the fix.** The second boot attempt failed
   identically because I had added the `import` statement and a paragraph
   explaining `imports: [AdminAuthModule]` without adding it to the decorator.
   Re-running the same check caught it; re-reading my own diff had not.
3. **The most serious defect was found by reading production data, not code.**
   `PATCH` originally replaced the document. Only after querying
   `feed_settings` and seeing that `weights` stores all fifteen entries was it
   clear that a one-field write would silently drop fourteen. Today the values
   equal the compiled defaults, so nothing would have visibly broken — the bug
   would have surfaced later, as a mysteriously reverted tuning.
4. **Setting Render env vars does not deploy them** (carried over from Stage 1,
   and worth repeating in any runbook).

---

## 10. What I did not do

- Did not push, deploy, apply a migration, or touch Render configuration.
- Did not add range validation to ranking weights (§2A rationale).
- Did not build 2B-1 despite it being cheap and high-value — it is 2B, and the
  instruction was to implement 2A only.
- Did not migrate any client constant. Every one requires an APK, so they belong
  in a single batched release, not dribbled out.
