# Phase 0 + Phase 1 — Remote Configuration Plane: Implementation Plan

Scope locked per approval: **Phase 0** (reusable config platform) and **Phase 1**
(infrastructure-level values only). No workflows move, no UI redesign, no
escrow/jobs changes, no schema-driven rendering. The one schema change
(`app_settings`) is **written but never applied** — it stops for explicit
approval. Architecture review: `docs/backend-centric-architecture-assessment.md`.

---

## 1. Design

One new backend module and one new client service, both cloned from mechanics
that already survived production in this codebase:

```
app_settings (table, LATER, needs approval)        compiled defaults (now)
        └────────────── merged under ──────────────────────┘
                AppConfigService  (60s cache, per-key type guards,
                                   failed query → last-good pinned)
                        │
        GET /config  (@Public, rate-limited, ETag/304, allowlist projection)
                        │
        RemoteConfigService (Flutter singleton, ChangeNotifier)
          compiled defaults → SharedPreferences cache → async refresh
          (launch post-frame + resume, TTL 15 min, never blocks launch,
           never throws, wrong-typed keys ignored per key)
                        │
        consumers: kill switches · maintenance banner · announcement ·
                   min-version gate · payment/promotion poll knobs ·
                   urgent-window minutes
```

Decisions (each mirrors an existing house rule):

- **Fail-open for feature switches** (absent/unfetchable = enabled), because
  config unavailability must never disable commerce. **Fail-closed only for
  nothing** in Phase 1 — maintenance mode activates solely on an explicit
  fetched `active: true`.
- **The endpoint works with zero DB rows.** Same as `FeedSettingsService` when
  migration 090 was pending: query error → defaults. So all code ships and
  runs before the table exists.
- **Version = SHA-256 hash of the canonical merged payload** (first 16 hex),
  doubling as the ETag. Deterministic — no timestamps in the body.
- **Allowlist projection**: the response is built field-by-field from the typed
  contract; unknown table keys can never leak to clients.
- **Client hard gates act at cold start from cached config** — a hard
  min-version or a fetched maintenance flag never yanks a mid-session flow.
- **Launch transaction untouched**: warm-up reads only SharedPreferences;
  the network refresh fires after the first frame.

## 2. Files

**Backend — new module `backend/src/app-config/`**

| File | Why |
|---|---|
| `client-config.ts` | The typed client contract + compiled defaults (`ops.kill_switches`, `ops.maintenance`, `ops.min_version`, `ops.announcement`, `tuning.payments`, `tuning.listings`) — one place, snake_case wire shape |
| `app-config.service.ts` | Loader over `app_settings`: FeedSettings mechanics with the *stronger* guard set (array + `Number.isFinite` checks), 60 s cache, last-good pinning, version hash, `invalidate()` |
| `app-config.controller.ts` | `GET /config` — `@Public` with reason, `config:read` policy, `If-None-Match` → 304, `platform`/`app_version` params accepted for observability |
| `app-config-admin.controller.ts` | `GET /admin/config` + `PATCH /admin/config/:key` — `AdminAuthGuard` + `senior_admin`, key allowlist, mirrors the promotion-settings admin surface |
| `app-config.module.ts` | Wiring; exported service so backend features can later read the same switches |
| `app-config.service.spec.ts`, `app-config.controller.spec.ts` | Defaults-on-empty, per-key guard rejection, outage pinning, deterministic version, 304 behaviour, projection |

**Backend — edits**

| File | Why |
|---|---|
| `backend/src/common/rate-limit/rate-limit.policies.ts` | Add `config:read` policy (launch + resume + 15-min TTL cadence; CGNAT-sized IP rule) |
| `backend/src/app.module.ts` | Register `AppConfigModule` with the feature modules |

**Mobile — new**

| File | Why |
|---|---|
| `lib/models/remote_config.dart` | Typed model + per-key guarded parsing + compiled defaults + semver compare — pure Dart, fully unit-testable |
| `lib/services/remote_config_service.dart` | Singleton `ChangeNotifier`: cache → refresh lifecycle, ETag, TTL 15 min, never throws |
| `lib/widgets/ops_banners.dart` | Announcement / maintenance / soft-update banners + the blocking hard-update screen |
| `test/remote_config_test.dart` | Parsing, guards, defaults, semver, switch fallback, corruption cases |

**Mobile — edits**

| File | Why |
|---|---|
| `lib/config/api_config.dart` | `/config` endpoint constant |
| `lib/screens/home_screen.dart` | Mount banners above the tab stack; warm-up + resume refresh; hard-gate check |
| `lib/screens/payment_screen.dart` | Poll budget/interval from config (defaults unchanged); payments kill switch at `_submit` |
| `lib/screens/promotion/promote_listing_flow_screen.dart` | Same for the campaign loop; promotions switch at `_payNow` |
| `lib/services/post_service.dart` | Posting switch at `createPost`; urgent window minutes from config (default 60) |
| `lib/services/application_service.dart` | Applications switch at `submitApplication` |

**Migration (written, NOT applied):** `supabase/migrations/109_app_settings.sql`
— `app_settings(key text pk, value jsonb, updated_at)`, RLS enabled, service-role
policy only, seeded with values equal to the compiled defaults. Stops for approval.

## 3. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Config outage disables a feature | Switches fail open; absent key = enabled; compiled defaults are the floor |
| Bad value in SQL editor | Per-key type guards on **both** sides; one bad key degrades one value |
| Corrupt device cache | Parse inside try/catch → compiled defaults; cache overwritten on next good fetch |
| Startup latency | Warm-up = one prefs read; network strictly post-frame; verified no new work inside `LaunchSequence` |
| Old clients | Never call `/config`; no existing endpoint or payload changed |
| New client + old backend (404 on `/config`) | Treated as fetch failure → defaults; app identical to today |
| Wrongly flipped kill switch (operator error) | Switches gate *actions* with friendly copy, never crash paths; recovery = PATCH + 60 s TTL + client refresh on resume |
| Rate-limit misconfig aborts boot | Catalogue validated at construction — a bad policy fails the deploy, not production traffic |

## 4. Rollback

- Backend: remove `AppConfigModule` from `app.module.ts` (one line) or revert
  the commit; module is a leaf — nothing imports it.
- Client: every consumer reads config **with today's constant as the default**,
  so reverting = the config simply never differing from defaults. Killing the
  fetch (revert commit) restores byte-identical current behaviour.
- Migration: not applied in this phase; if later applied, rollback is
  `drop table app_settings` (no other object references it).

## 5. Verification results (executed, not projected)

Backend: `tsc --noEmit` clean; **530 tests pass** (31 suites, 1 skipped = the
Redis integration spec needing `REDIS_TEST_URL`), including 28 new app-config
specs. The new controllers were added to `auth.contract.spec.ts`, so they are
covered by the same build-time scheme/DTO checks as every other route.

**Boot audit under `AUTH_ENFORCEMENT=enforce`** (findings are fatal in that
mode): 108 routes, `undeclared=0`, "Every route declares a scheme and every
admin route is guarded", with `GET /config` listed in the printed public surface
alongside its reason.

**Live HTTP against a real running server**, booted with a deliberately invalid
Supabase key and no Redis — i.e. both dependencies down:

| Check | Result |
|---|---|
| `GET /config` with Supabase unreachable | `200`, complete document, compiled defaults — proves the migration-absent and DB-outage paths |
| Redis unreachable | `RateLimit-Degraded: true`, endpoint unaffected |
| Response body | byte-identical to the Dart golden test's expected JSON |
| Payload size | 413 bytes |
| `If-None-Match` matching | `304`, 0 bytes |
| Stale ETag | `200`, full body |
| `?platform=&app_version=` | `200`, accepted and ignored |
| Latency, 10 sequential | 2.2–4.1 ms |
| `GET /admin/config`, `PATCH /admin/config/:key` | `401` — guarded |
| `/health`, `/`, `/promotions/packages` | `200` — unchanged |
| `/feed` | `503` — its documented client-fallback signal with no DB, unchanged |

**A rate-limit defect was found by this burst testing and fixed.** The first
`config:read` policy used the house subject+IP pair. But `resolveIdentity` keys
a subject rule on `fallback-ip:<ip>` when no `user_id` resolves — and `/config`
is read overwhelmingly by clients with no identity attached. The 60/min subject
rule was therefore acting as a 60/min limit per **CGNAT address**, 20× tighter
than the IP rule beside it, on the one endpoint that must answer when every
device relaunches at once. Measured: 70 anonymous requests → 7 × `429`. Replaced
with a single crowd-sized IP rule; re-measured: **200 anonymous requests → 0 ×
`429`**, `RateLimit-Limit: 3000`.

Mobile: `flutter analyze` reports **no issues in any new or modified file** (the
69 repo-wide findings are pre-existing, including an already-unused
`payment_utils` import in `payment_screen.dart` that predates this work).
**728 tests pass**, up from 708 — 42 new across two suites:

- `remote_config_test.dart` (22): compiled-defaults floor, a **golden assertion
  that the Dart and TypeScript default documents are byte-equivalent**,
  per-key type guards, clamps, non-finite values, forward compatibility with
  unknown fields from a newer server, semver edge cases (missing segments,
  build/pre-release suffixes, malformed input), and that an explicit
  all-switches-off document is still obeyed.
- `remote_config_service_test.dart` (20): cold start on a fresh install
  (asserting `warmUp` issues **zero** network requests), warm start from cache,
  offline, `500`, `404` (new APK against a backend without the route),
  malformed body, partial body, ETag emission and `304`, TTL skip vs TTL
  expiry, corrupt cache, the launch-snapshot rule for the hard gate,
  announcement dismissal persistence, and listener notification.

Startup cost measured by construction: `warmUp()` is one `SharedPreferences`
read plus one `PackageInfo` lookup, asserted network-free by test; the fetch is
a post-frame callback. Memory is one small immutable document. Network overhead
in the steady state is one 304 per launch or resume, at most once per 15 min.

## 6. Testing

- Backend: new specs + full `npm test` suite green.
- Mobile: `flutter analyze` clean + new unit tests + full `flutter test` green.
- Scenario matrix (unit-level): empty table / missing table / partial rows /
  wrong types / NaN / non-object rows / outage pinning / 304 / version
  stability / semver edge cases (equal, prerelease-less compare, malformed) /
  switch absent / switch false / maintenance absent.
- Manual reasoning documented per requirement: cold start, offline, backend
  down, cache expiry, old↔new compatibility, Redis/Supabase down, memory and
  network overhead.
- Device QA (adb) for cold-start timing remains owed after deploy, per the
  standing device-verification-first rule.

## 7. Production rollout — COMPLETED 2026-08-07

**Stage 1 — migration 109 applied.** Pre-flight confirmed `app_settings` did not
exist in any schema, no policy/constraint/relation name collisions, no function
or view referencing it, and that `pg_default_acl` grants new tables to
`service_role` only (so no accidental anon exposure was possible). Baseline
fingerprint recorded before applying: 47 tables, 73 policies, 61 routines, 19
triggers, 109 anon/authenticated grants.

After applying: 48 tables (+1), 74 policies (+1), routines and triggers
**unchanged**, client grants **still 109**, and the policy fingerprint computed
over every table except the new one was **byte-identical to baseline** — proving
no existing policy was touched.

| Verification | Result |
|---|---|
| Seed vs compiled defaults | Reassembled document is `jsonb`-equal to `DEFAULT_CLIENT_CONFIG` — the migration provably cannot change behaviour |
| RLS | enabled, one policy, `cmd=ALL roles={service_role}` |
| Grants | anon and authenticated hold **no** privilege of any kind |
| Real role-switch probe | anon SELECT / INSERT / **UPDATE of the kill switches** → all `permission denied`; authenticated SELECT → denied; service_role SELECT → allowed |
| CHECK constraint | rejects array and string values |
| Seed idempotency | re-running is a no-op; `payments: true` was not clobbered |
| Rollback preconditions | 0 inbound FKs, 0 dependent views, 0 triggers → `DROP TABLE` succeeds cleanly, no CASCADE |
| Security advisors | `app_settings` appears in **none**; all findings pre-existing on other objects |
| Production before push | `/health`, `/`, `/promotions/packages` → 200; `/config` → 404 (module not deployed) |

**Stage 2 — pushed `e186bf8`; Render auto-deployed.** Verified live:

| Check | Result |
|---|---|
| `GET /config` | `200`, and **version `3b6c0888a44bf4c1` — the identical hash produced when the table was absent**, confirming the seed changed nothing |
| Conditional request, strong ETag (what the client sends) | `304`, 0 bytes |
| Conditional request, weak `W/"…"` (what the proxy advertises) | `304`, 0 bytes |
| Stale / absent ETag | `200`, 413 bytes |
| `GET /admin/config`, `PATCH /admin/config/:key` | `401`, including with a junk bearer |
| Regression sweep — `/health`, `/health/{database,redis,firebase,events}`, `/`, `/promotions/packages`, `/promotions/slots`, `/reputation`, `/feed`, `/mpesa/health` | all `200` |
| Latency | 0.5–1.1 s cold-ish over the public internet; 2–4 ms locally |

**End-to-end control-plane test in production.** Changed one benign key
(`ops.announcement`) via SQL, confirmed `/config` served the new value with a
new version hash (`ed3525777713517d`) while every other field stayed at its
default, then restored it and confirmed production returned to
`3b6c0888a44bf4c1` within the 60 s cache window. This proves the backend genuinely
reads `app_settings`, that the merge-under-defaults works, and that ETags
invalidate on change. The announcement key was chosen deliberately: it exercises
the identical code path as a kill switch at zero risk, and no shipped APK reads
`/config` yet.

**Correction to the assessment.** `docs/backend-centric-architecture-assessment.md`
§7 lists `public.notification_queue` as a critical RLS-disabled exposure. Verified
against the live catalog: RLS is indeed disabled, but the table holds **zero
anon/authenticated grants**, so PostgREST denies access by grant. It is not
reachable with the shipped key, and the advisors no longer flag it. The severity
was overstated; it remains a dead-table cleanup candidate, not an exposure.

## 8. Deployment

1. All code lands in one reviewed commit series on `main` **only after** the
   full verification above passes.
2. Push → Render auto-deploys the backend. Live effect: one new public GET
   serving compiled defaults; one admin surface that 503s harmlessly until the
   table exists. Zero effect on shipped APKs.
3. Mobile changes reach users only with the next APK build (user-controlled).
4. `app_settings` migration: presented for approval separately; until applied,
   PATCH returns a clear error and GET serves defaults — by design.
