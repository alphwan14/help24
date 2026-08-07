# Help24 — Backend-Centric Architecture Assessment

Status: **assessment only. No code has been changed. No migration has been applied.**
Every claim below was verified against the working tree (and, where noted, the live
database catalog — reads only). Implementation begins only after this assessment
is approved, and any schema change stops for explicit per-change approval first.

Companion documents: `docs/production-hardening-plan.md` (identity/RLS/ledger — still
awaiting its own approval; nothing here depends on it, nothing here conflicts with it).

---

## 1. Executive summary

Help24 is **not** an app-centric product with a thin API bolted on. The NestJS
backend already owns everything that moves money or reputation: escrow settlement,
dispute arbitration, review eligibility, reputation recompute, promotion pricing
and serving, the job lifecycle, and a 15-signal Discover ranking engine with a
DB-tunable settings layer. That work does not need redoing, and this assessment
recommends **not** touching it.

The real architecture, verified transport by transport:

- **Money, lifecycle, ranking → NestJS** (Firebase ID token, verified server-side,
  identity bound per route, staged `AUTH_ENFORCEMENT` currently in `monitor`).
- **Profiles, posts, applications, chat, notifications, saved items, reports,
  reference data → direct Supabase PostgREST/Realtime under RLS** (exchanged JWT,
  silently degrading to the anon key when the token bridge fails).
- **Identity, push → Firebase SDKs.**

Three structural gaps are where the app-centric risk actually lives:

1. **There is no operational control plane.** Grep-verified on both sides: no
   feature flags, no kill switch, no maintenance mode, no minimum-app-version
   gate, no Firebase Remote Config, no flags package in `pubspec.yaml`. Between
   "edit `feed_settings` in SQL" and "publish a new APK through Play review"
   there is nothing. At 100k+ users, a client-side payment bug has a
   multi-day exposure window with no mitigation lever.

2. **The two highest-volume writes carry their business rules on the client.**
   Post creation and application submission are direct Supabase inserts. Every
   validation rule (title, price > 0, image caps, category rules), the urgent
   window (`now + 1h` **computed from the device clock**), and the
   provider-readiness gate (which **fails open** on read errors) exist only in
   Dart. There are no posting or application rate limits anywhere.

3. **Duplicated decision logic has already drifted.** The platform-fee table is
   byte-mirrored between `payment_utils.dart` and `fee.ts` and already disagrees
   below KES 100. The escrow state is derived twice (a hand-rolled ladder in
   `job_status_card.dart` vs the backend's canonical `deriveSettlementState`),
   and the client ladder has a provably dead branch — the "Finalizing payout"
   state can never render. Campaign allowed-actions, tier vocabulary,
   notification taxonomy and report reasons are each transcribed 2–3×.

The recommended transformation is therefore **not** "put NestJS in front of
Supabase". The direct reads, the realtime channels, the bundled reference-data
floor and the feed fallback are deliberate, load-bearing resilience design —
they are what keeps the app alive when the Render backend cold-starts or drops.
The transformation is:

- **Serve decisions, render on the client** — fee quotes, settlement state,
  allowed actions, eligibility come from the backend; Dart keeps only
  presentation maps and offline fallbacks.
- **Centralize the two rule-carrying writes** behind NestJS endpoints, staged
  with the same monitor-then-enforce pattern `AUTH_ENFORCEMENT` already proved.
- **Generalize the house config pattern** (`feed_settings` / `promotion_settings`
  merge-under-defaults, 60 s cache, per-key type guards) into one client-facing
  remote configuration surface: kill switches, maintenance mode, min-version,
  and the tunables that today require an APK.

Everything else — and it is most of the codebase — is either already correct
(Group A), genuinely native (Group C), or a hybrid whose split is right (Group D).

---

## 2. How the app and backend communicate today (verified)

| Path | Client | Credential | Used for |
|---|---|---|---|
| NestJS on Render (`help24-backend.onrender.com`) | `Help24ApiClient` (`services/api_client.dart`) | Raw Firebase ID token; server verifies via Admin SDK, binds UID onto one declared field per route (`identity-binding.ts`) | M-Pesa, escrow status, job lifecycle, disputes, promotions, reviews, reputation, `/feed`, interactions, chat push fan-out, routes proxy, availability |
| Supabase PostgREST / Realtime / Storage | `HttpClientWithToken` injected at `Supabase.initialize` | Exchanged Supabase JWT via `exchange-firebase-token` edge function; **anon key when exchange fails** | Profiles, posts, post_images, applications, chat, notifications, saved, reports, fcm_tokens, reference registries, deep-link resolution |
| Firebase SDKs | `firebase_auth`, `firebase_messaging` | Firebase session | Sign-in/up/link, phone OTP, push receipt |

Load-bearing facts:

- The backend talks to Supabase **only** through the service-role key
  (`supabase.service.ts:10-14`) — one client, RLS bypassed, backend is the
  authorization boundary for everything it owns.
- The app performs **16 distinct direct-write site groups across 10 tables + 2
  storage buckets** (full list in §3, Group B/D rows). Only four of those paths
  proactively refresh the JWT before writing; the rest recover after a 401.
- `/feed` failure, an 8 s timeout, a non-200, or an **empty first page** all
  silently reroute Discover/Jobs/Search to direct PostgREST reads ordered
  `created_at desc` (`feed_service.dart:216-238`, `post_service.dart:206`).
  The backend explicitly designs for this (`app.module.ts:84`).
- Zero `.rpc()` calls in the app; one edge function (token exchange). The
  `send-chat-push` edge function is dead code from the app's perspective —
  chat push goes through NestJS, and the client logs any push not stamped
  `emitter=nestjs` as a foreign-emitter incident.
- Offline = SharedPreferences everywhere + bundled JSON assets as the
  reference-data floor (no sqlite/Hive). Session-scoped keys are purged on
  sign-out by `session_scope.dart`.

---

## 3. Architecture inventory

### Group A — already correctly backend-driven. Do not modify.

| Feature | Why it is correct |
|---|---|
| **Escrow settlement engine** | `settleByTransaction` (`mpesa.service.ts:581-696`) is the single idempotent terminal writer; release source-state gate; reconcile never settles on age — waits for a confirmed Daraja status result. Client never sees `transactions`/`escrow` tables (S2 lockdown, verified: zero references in `lib/`). |
| **Dispute arbitration** | Role-gated decisions, case-lock, financial types need `senior_admin`, auto-priority from escrow amount, SLA auto-escalation sweep, payout math validated server-side (`decisions.service.ts`). |
| **Review eligibility + submission** | One server-side `evaluate()` gate for both GET and POST (`reviews.service.ts:109-188`); client `ReviewEligibility` is a DTO and fails closed. |
| **Reputation** | Zero rating math in Dart (verified); recompute via `fn_recompute_provider_reputation`, triggered on approve/resolve/review; wire shape defined once. |
| **Discover ranking** | 15 signals, weights and sub-configs DB-tunable via `feed_settings` merged under compiled defaults with per-key type guards (`feed-settings.service.ts:34-104`); deterministic rotation buckets; null-means-not-applicable scoring. |
| **Promotions** | Pricing lives only in `promotion_packages` (campaign snapshots price at purchase); campaign state machine + serving eligibility correct-by-query + rotation + derived analytics all server-side; `moderation.auto_approve` is a real DB-driven behaviour switch. |
| **Job lifecycle writes** | select-provider / mark-complete / approve / archive are backend-only with author/provider checks, payment-confirmed gates, dispute/held-funds blocks (`jobs.service.ts`). Client comment records the direct writes were deliberately removed. |
| **Reference data registries** | `professions`/`locations`/`profession_categories` + `registry_versions` server tables, bundled JSON floor, 24 h client cache — "add a town with one INSERT, no app release" already works. Generated seeds, never hand-edited. |
| **Auth identity binding + staged enforcement** | `@Auth`/`@Public` declarations, boot-time route audit (findings fatal in `enforce`), monitor-mode `authWouldDeny` counter — this is the house rollout pattern §6 reuses. |
| **Rate limiting** | 20-policy catalogue validated at boot, Redis with bounded fail-open, headers on every response. (Gap: nothing covers the direct-Supabase writes — see Group B.) |
| **Routes proxy** | Google Routes key stays server-side; budget applied after cache. |
| **Chat push fan-out** | Data-only Android messages, server-built 7-message thread, emitter fingerprint, invalid-token cleanup (`notifications.service.ts`). |

### Group B — business logic in Flutter that should move behind the backend

Each row: current implementation → proposed backend implementation. Benefits and
risks are in the ranked table (§4), which is the decision surface.

| # | Logic | Current (client) | Proposed |
|---|---|---|---|
| B1 | **Platform fee table** | Hardcoded tiers in `payment_utils.dart:1-29`, manually mirrored from `fee.ts`, already divergent < KES 100; displayed total computed in Dart (`payment_screen.dart:87`) | Fee quote served by the backend (config-driven tiers); client renders served numbers, keeps the compiled table only as an offline display fallback |
| B2 | **Escrow/job state ladder** | `_JobData.state` 8-state precedence ladder in `job_status_card.dart:21-87`, duplicating `deriveSettlementState`; dead `payoutInProgress` branch (`post_model.dart:336` — never set true) | `JobStatusCard` consumes the settlement object the backend already returns on `GET /jobs/:postId/lifecycle`; Dart keeps only a state→(icon, colour, label) render map |
| B3 | **Post creation + validation** | Direct Supabase insert (`post_service.dart:416`); all rules client-only: title required, price > 0, 5 images / 5 MB, category shape, job description requirement; `urgent_expires_at = device now + 1h` (`post_service.dart:409-411`); no rate limit; no moderation hook | `POST /listings` NestJS endpoint owning validation, urgent window (server clock, config-driven duration), posting rate limits, future moderation seam. Client keeps instant UX validation (hybrid) |
| B4 | **Application submission + eligibility** | Direct insert (`application_service.dart:84`); self/duplicate checks client-side (DB trigger + unique constraint as backstop); provider-readiness gate **fails open** (`provider_gate.dart:93-97`); separate fire-and-forget notify call | `POST /applications` owning eligibility (self, duplicate, open-post, provider-ready fail-closed), rate limits, and the notification in one transaction-shaped flow |
| B5 | **Promotion eligibility + campaign actions** | Promotable = `type == offer && status == 'open'` filtered in Dart (`promote_listing_flow_screen.dart:62-64`); Pause/Resume/Cancel offered by a Dart copy of the transition table (`campaign_detail_screen.dart:259-299`) | Backend serves `eligible_for_promotion` on owned posts and `allowed_actions` on campaign DTOs from `campaign-state.ts` — the authority that already exists |
| B6 | **Profile completion** | Weights (photo 20, name 10, phone 20, profession 25, bio 25), min-bio 40, next-step selection — all in `profile_completion.dart`, no server counterpart | Served on the profile read path (weights in remote config); client falls back to the local computation offline |
| B7 | **Operational constants requiring an APK to change** | Payment poll budget (24×5 s, two independent copies), urgent-window duration, sponsored-slot fallbacks (7/8), reputation cache TTLs, location accuracy thresholds (50/150 m), journey geofence rules (`journey_engine.dart:245-283` — arrival radius 100 m, dwell 60 s, keepalive 30 s…), upload/text caps, page sizes, price-slider bounds (0–100 000) | Remote config surface (§5) — served, cached, compiled-defaults floor |
| B8 | **Notification taxonomy/routing** | 32-type Dart registry with priority/category/route (`app_notification.dart:214-488`) vs backend's 22-type union; two tap routers that disagree on `review_received` | Server stamps `category/priority/route` hints on notification rows; client keeps icon map + its existing `unknown` fallback for forward compatibility |

### Group C — must permanently remain in Flutter (native platform)

| Capability | Why it stays |
|---|---|
| GPS acquisition + the 50 m/150 m accuracy gate (`location_service.dart:148-262`) | The gate judges the **device sensor's** claimed accuracy before a coordinate exists anywhere; only the device can do this. (The thresholds become config knobs — the gate itself stays.) |
| On-device geocoding (`place_name_cache.dart` documents "no Google Geocoding API") | Platform geocoder; keeps a billable API off the stack. |
| FCM receipt, notification channel rendering, background isolate MessagingStyle, device-local mutes honoured while killed | OS integration by definition. |
| Image pick/downscale (1200×1200 q85) before upload | Camera/gallery APIs + upload-size economics belong at the edge. |
| SharedPreferences caches, outbox, session scoping, bundled asset floor | Offline capability is the client's core responsibility. |
| Realtime socket lifecycle, reconnect backoff, polling degradation | Connection management from the device's side of the network. |
| FeedSnapshot frozen rendering + install-vs-splice | Pure render stability — prevents a list re-sorting under the reader's thumb. It renders a server ranking; it does not create one. |
| Navigation, deep links, animations, theme, l10n | Presentation. |

### Group D — hybrid by design (correct split, keep the split)

| Feature | Client responsibility | Backend responsibility |
|---|---|---|
| **Auth** | Firebase SDK flows, token caching, one-replay-on-401 | Admin-SDK verification, identity binding, enforcement staging; DB triggers guard privileged columns |
| **Feed** | Fallback fetch when `/feed` is down, snapshot stability, telemetry batching | Ranking, retrieval, diversity, tuning |
| **Chat** | PostgREST writes + realtime + offline outbox (latency-critical; a backend hop would degrade UX) | Push fan-out; *(future, flagged in §7: moderation/abuse controls — currently nothing exists)* |
| **Notifications** | Single-owner store, unread reconcile, rendering | Emission (22 types), bell-row persistence, FCM multicast |
| **Payments** | STK progress UX, polling (budget becomes config) | Everything that is true about money |
| **Location** | Sensor acquisition + accuracy gate | Distance scoring inside ranking (`viewer-context` + distance signal) |
| **Reference data** | Bundled floor + cached sync | Registry tables + `registry_versions` |

---

## 4. Ranked migration opportunities

Value = operational benefit at 100k→10M users, i.e. "what can we change or kill
**without publishing an APK**, and what blast radius does it remove".

### High value

| # | Item | Operational benefit | Risk | Schema change? |
|---|---|---|---|---|
| H1 | **Remote configuration + control plane** (§5): kill switches, maintenance mode, min-supported-version, tunables | Today: zero levers between SQL and a Play release. After: payments/promotions/chat-push can be disabled in seconds during an incident; a bad client build can be soft-blocked; every B7 constant becomes tunable. This is the prerequisite that de-risks every other rollout (each migration ships behind a config flag with instant rollback). | **Low-medium.** Additive only; client floor = compiled defaults, so a missing/failed `/config` changes nothing. Kill switches default to "enabled" when absent (absence ≠ outage). | **Yes — one table** (`app_settings`, service-role-only RLS). **STOP: needs your approval.** Code can ship first and run on compiled defaults — the loader pattern tolerates a missing table. |
| H2 | **Fee quote served** (B1) | Fee changes without release; displayed total provably equals charged total; kills a live divergence. Smallest possible surface: extend `GET /mpesa/status` / add a quote read; tiers move into config. | **Low.** Display-side only — the server already recomputes the real charge on initiate. | No |
| H3 | **Settlement state consumed, not re-derived** (B2) | One truth for what a buyer/provider sees about held money; refund/partial flows can evolve server-side with zero client releases; kills the already-dead "Finalizing" branch class of bug forever. | **Medium.** `JobStatusCard` is on the hot path; needs cached-last-known + error presentation. Endpoint already exists and is participant-scoped. | No |
| H4 | **Post creation through backend** (B3) | Spam/abuse control on the highest-volume write (there is currently **no posting limit at all**); honest server clock on `urgent_expires_at`; validation changes and future moderation without APK. At 1M users this is the difference between a policy change and a release train. | **Medium-high** (highest-volume write). Mitigation: staged per §6 — config flag `posting.via_backend`, monitor-mode counter first, instant rollback to direct writes. Images continue via Storage. | No (same tables, same rows) |
| H5 | **Applications through backend** (B4) | Closes the fail-open provider gate with a fail-closed server check; application rate limits; eligibility becomes policy, not code. Merges the write + notify into one flow. | **Medium.** Same staging as H4. DB trigger + unique constraint remain as backstops. | No |

### Medium value

| # | Item | Operational benefit | Risk | Schema? |
|---|---|---|---|---|
| M1 | Campaign `allowed_actions` + promotion eligibility served (B5) | Promotion product iteration (e.g. promoting requests) without releases; deletes two transcriptions of the state machine | Low — additive DTO fields | No |
| M2 | Profile completion served (B6) | Growth lever: weights/next-step tuning, activating "coming soon" fields server-side | Low — offline falls back to local calc | No |
| M3 | Notification `category/priority/route` hints (B8) | New notification types reach old clients correctly; ends the two-router disagreement | Low-medium — payload additive, client fallback exists | No |
| M4 | Feed/search filter params passed to `/feed` (categories, price, difficulty, urgency, city/area) instead of client-side filtering of loaded pages | Filters apply to the whole corpus, not the fetched window; search/filter behaviour becomes tunable | Medium — query surface grows; fallback path already passes filters to PostgREST, so parity is testable | No |
| M5 | Profession-slug validation on the write path (server-side FK/registry check) | Data quality: `users.profession` can't silently hold junk; the registry is already the authority | Low | Possibly a trigger — **would stop for approval** |

### Low value

| # | Item | Note |
|---|---|---|
| L1 | Unify the two payment-poll loops into one client class; budget/interval from config | Client refactor; config knobs come free once H1 exists |
| L2 | Typing/presence heuristics (4 s vs 6 s inconsistency) unified; knobs optional | Cosmetic consistency |
| L3 | Reputation display thresholds + cache TTLs as config | Cheap once H1 exists |
| L4 | Review comment cap parity (`@MaxLength(1000)` server DTO) | One-line defect fix, do with Phase 0 |
| L5 | Name shape rules server-side | Cooldown already DB-enforced (087); shape is UX; low return |
| L6 | Bio caps (40/300) parity | Fold into whichever phase touches profile writes |

### Leave as is (deliberate non-migrations)

| Item | Why moving it would be overengineering |
|---|---|
| Feed fallback to direct Supabase reads | It is the availability story. Removing it couples Discover uptime to Render cold starts. |
| Chat persistence direct-to-DB + realtime | Latency-critical; RLS-scoped to participants; backend hop buys moderation only when moderation exists (flagged as future work, §7). |
| FeedSnapshot / install-vs-splice / notification single-owner store | Client-state correctness machinery, not business logic. |
| Owner-scoped small writes: saved items, notification read-marks, FCM token hygiene, local mutes | Trivial, personal-scope, RLS-appropriate; centralizing adds latency and backend load for zero policy value. |
| Reference registries' bundled floor + client cache | Offline-first done right; already server-versioned. |
| On-device geocoding | Moving it adds a billable API and a network dependency to get *worse* UX. |
| The 150 m accuracy **gate** location | Sensor-side by nature (threshold becomes a knob; the gate stays). |
| `feed_settings` / `promotion_settings` loaders | Already the pattern this plan generalizes. |

---

## 5. The remote configuration design (H1)

Generalize the proven house pattern; invent nothing new.

**Storage:** `app_settings(key text pk, value jsonb, updated_at timestamptz)` —
same shape as `feed_settings`. RLS: deny-all; service-role only. **This is the
one schema change in the entire plan → stops for your approval.**

**Backend:** `AppSettingsService` cloned from `FeedSettingsService` mechanics
(60 s cache, merge-under-compiled-defaults, per-key type guards, wrong-typed
values ignored, failed query pins last-good). One public endpoint:

- `GET /config?platform=android&app_version=<semver>` — `@Public` with reason,
  rate-limited, returns **only an allowlisted client-safe projection** (never a
  table dump), plus `config_version` for client-side change detection.
- `PATCH /admin/config/:key` — `AdminAuthGuard`, `senior_admin`, key allowlist —
  mirroring the existing `PATCH /admin/promotions/settings/:key`.

**Client:** `RemoteConfigService` mirroring `reference_registry.dart` mechanics:
compiled defaults → SharedPreferences cache → async refresh (launch + resume,
TTL ~15 min). **Never blocks the launch transaction** — startup renders on
cached/compiled values; a fetched change applies on the spot only where safe
(copy, limits) and at next cold start where not (min-version hard gate).

**Initial key set** (deliberately small; every key must earn its place):

| Key | Contents | Lever |
|---|---|---|
| `ops.kill_switches` | `{payments, promotions, chat_push, posting, applications}` booleans, absent = enabled | Disable a broken surface in seconds; each renders a friendly "temporarily unavailable" state that already exists as error UX |
| `ops.maintenance` | `{active, message, allow_reads}` | Planned windows; app shows banner / read-only mode |
| `ops.min_version` | `{soft, hard, message, store_url}` | Soft = dismissible banner; hard = blocking screen at next cold start. Also the only survivable path for a future Supabase anon-key rotation — today the key is a compile-time literal, so rotation would brick every installed client with no recovery lever |
| `payments.fees` | The B1 tier table + min amount | Fee changes without release |
| `listings.rules` | urgent window minutes, image caps, price bounds | Policy without release |
| `client.tuning` | poll budgets/intervals, page sizes, accuracy thresholds, reputation TTLs | The B7 long tail — added incrementally, not all at once |
| `rollout.flags` | `{posting_via_backend: off\|monitor\|enforce, applications_via_backend: …}` | §6's staged migrations |

Explicitly **not** in scope: per-user experiment bucketing, dynamic copy beyond
maintenance/kill-switch messages, server-driven UI. No measurable operational
need today; revisit at real scale.

---

## 6. Rollout strategy

House pattern, reused from `AUTH_ENFORCEMENT`: **off → monitor → enforce**, with
a counter proving safety before each flip, and every phase independently
committable, verifiable, and revertible. One feature per phase; no giant refactor.

- **Phase 0 — defect fixes (no architecture change):** §7 items. Each is small,
  testable, and reduces noise before behaviour comparisons start.
- **Phase 1 — config foundation:** backend service + endpoint + client service,
  all running on compiled defaults (works with zero DB rows). Then **stop for
  migration approval** of `app_settings`; seed after approval. Verify: endpoint
  parity with defaults, client cold-start unchanged (launch-transaction timing),
  offline behaviour, kill-switch drill in dev.
- **Phase 2 — truth consolidation (read-side):** H2 fee quote, H3 settlement
  consumption, M1 allowed-actions. Verify each by golden-value parity tests
  (Dart table vs served values; ladder vs settlement object over recorded
  fixtures) before deleting any client derivation. Old clients unaffected —
  fields are additive.
- **Phase 3 — write centralization:** H4 then H5, each: endpoint ships →
  `monitor` (client still writes direct; backend validates the same payload and
  logs `wouldReject` with reasons) → compare counters to zero → `enforce` (client
  writes via backend; direct-write fallback retained one release) → remove
  fallback. Rate limits activate at enforce.
- **Phase 4 — long tail:** M2–M4, L-items, knob expansion as needed.

Compatibility rules binding every phase: no endpoint removed until its
replacement is verified in production; no DTO field repurposed — additive only;
old APKs keep working against the new backend indefinitely; deployment stays a
plain Render auto-deploy (no coordinated releases).

**Verification design** (applies per feature, per the existing house standards):
backend unit specs beside the code (`*.spec.ts`, as `settlement-state.spec.ts`
does today); Dart/TS parity fixtures for every migrated rule; `flutter analyze`
+ the existing test suite; the QA checklist rows relevant to the touched flow
(payments, feed, chat, notifications, offline) driven on a device via adb —
per the standing device-verification-first rule; monitor-mode counters as the
gate for every enforce flip; and a final old-APK-against-new-backend smoke pass.

---

## 7. Defects found during reconnaissance (fix regardless of the transformation)

Ordered by severity; none require schema changes except where marked.

1. **`public.notification_queue` has RLS disabled** (live-catalog advisory,
   critical): anyone with the shipped anon key can read/modify all 125 rows —
   notification content is PII. Comment says it feeds an Edge Function processor,
   but chat push now goes through NestJS and the app calls no queue — **likely a
   dead legacy table.** Needs a decision: retire it, or enable RLS (policy
   change → approval). Investigate the Edge Function's liveness first; do not
   blindly `ENABLE ROW LEVEL SECURITY` on a table a live function still drains.
2. **`MPESA_B2C_TIMEOUT_URL` points at a route that does not exist** —
   validated against `/mpesa/b2c-timeout` (`configuration.ts:71`) but no
   controller registers it; Daraja queue-timeout callbacks 404. Either register
   the handler or repoint the env; reconcile `.env.example` (also missing
   `MPESA_TXN_STATUS_RESULT_URL`).
3. **Fee divergence < KES 100** — client shows a fee for amounts the server
   rejects (superseded by H2, or a one-line guard now).
4. **Dead `payoutInProgress`** — never set since the S2 lockdown removed its
   data source; completed cards show green "Completed" during payout and
   `closedListingReason`'s "being finalised" branch is unreachable (superseded
   by H3).
5. **Two notification routers disagree** — `review_received` from the OS tray
   lands on the list; the same row tapped in-app opens the profile.
6. **Chat unread badge sums only the loaded page** (20 conversations).
7. **Provider gate fails open** on profile-read errors (superseded by H5;
   interim: fail closed with a retry affordance).
8. **Review comment cap client-only** — add `@MaxLength(1000)` to the DTO.
9. **Money path uses the looser of two phone validators** (`phone_utils` vs
   `KenyanPhone`) — unify on the strict one.
10. **Typing freshness 4 s vs 6 s** in two files.
11. **Unreachable code to remove:** client hard-`deletePost`
    (`post_service.dart:580-601`), backend `AdminService.resolveDispute` +
    executors (410-tombstoned).
12. **Scale note (document, don't fix now):** all backend settings/package/
    viewer caches are process-local; a settings edit converges within 60 s but
    `invalidate()` clears one replica only. Fine at one instance; revisit
    before horizontal scaling.

Already tracked elsewhere (not re-litigated here): open `users` RLS +
signup-race + identity plan (`production-hardening-plan.md`, awaiting approval);
Firebase console gaps (OTP 17093, SHA-256, authorized domains, Play Integrity);
release currently signed with the debug key.

---

## 8. What I will not do without your explicit approval

1. Apply **any** migration or DDL (`app_settings`, RLS changes, triggers) —
   each stops with why/impact/rollback first. *(Standing rule, permanent for
   this repository.)*
2. Write to production data in any form.
3. Remove or change the behaviour of any existing endpoint.
4. Flip any staged rollout to `enforce`.
5. Commit/push (Render auto-deploys `main`) — each phase is presented, verified,
   then pushed only with your go-ahead.

**Proposed starting order on approval:** Phase 0 defects → Phase 1 config
foundation (code first, table approval when we get there) → Phase 2 fee quote →
settlement consumption. H4/H5 only after Phase 1's flag machinery exists.
