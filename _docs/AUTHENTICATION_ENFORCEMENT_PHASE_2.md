# Priority 2 — Authentication Enforcement

**Status:** implemented, shipped in `monitor`. Enforcement is an environment
variable away.
**Scope:** move Help24 from asserted identity to verified Firebase identity
without a breaking rewrite and without downtime.

---

## 0. The finding that shaped everything else

The audit said "many endpoints trust user IDs coming from the client". That is
true, and it reads like forty endpoints are missing authorization. They are not.

Every service in this codebase **already performs the correct ownership check**:

| Service | Check |
|---|---|
| [jobs.service.ts:267](../backend/src/jobs/jobs.service.ts#L267) | `post.author_user_id !== dto.client_user_id` → 403 |
| [jobs.service.ts:160](../backend/src/jobs/jobs.service.ts#L160) | `post.selected_provider_id !== dto.provider_user_id` → 403 |
| [campaigns.service.ts:91](../backend/src/promotions/campaigns.service.ts#L91) | `campaign.owner_user_id !== userId` → 403 |
| [promotion-payments.service.ts:110](../backend/src/promotions/promotion-payments.service.ts#L110) | `campaign.owner_user_id !== userId` → 403 |
| [disputes.service.ts:438](../backend/src/admin/disputes/disputes.service.ts#L438) | `assertParticipant` on every method |

The defect is narrower and entirely in the **input**: the value being compared
arrives in the request body, so the caller chooses who they are.

That reframing is the whole design. The fix is not "add authorization to forty
endpoints" — it is **"make one field trustworthy, at one seam, before the
handler runs."** Bind the verified UID onto the field the service already reads,
and every existing check becomes sound with **zero changes to any service**.

**No business logic was modified.** The diff is: one new `common/auth` module,
one decorator per route, and the client sending a header it already mints.

---

## 1. Architecture

### 1.1 Request path

```
                    ┌─────────────────────────────────────────────┐
   HTTP request ───►│ 1. RequestContextMiddleware                 │  opens ALS, sets X-Request-Id
                    ├─────────────────────────────────────────────┤
                    │ 2. AccessLogMiddleware                      │  attaches finish/close listener
                    ├─────────────────────────────────────────────┤
                    │ 3. IdentityMiddleware      ◄── RESOLVES     │  verify ONCE → req.auth
                    │      └─ TokenVerifierService                │  (never rejects)
                    └───────────────────┬─────────────────────────┘
                                        │
                                   [ ROUTING ]
                                        │
                    ┌───────────────────▼─────────────────────────┐
                    │ 4. RateLimitGuard      (global APP_GUARD #1)│  keys on req.auth.uid
                    ├─────────────────────────────────────────────┤
                    │ 5. AuthGuard           (global APP_GUARD #2)│  ENFORCES + BINDS
                    ├─────────────────────────────────────────────┤
                    │ 6. AdminAuthGuard      (controller-scoped)  │  admin routes only
                    ├─────────────────────────────────────────────┤
                    │ 7. ValidationPipe      (global)             │  sees the bound field
                    ├─────────────────────────────────────────────┤
                    │ 8. Controller → Service → ownership check   │  UNCHANGED
                    └─────────────────────────────────────────────┘
```

### 1.2 The resolve/enforce split

**Verification happens exactly once, in middleware. The guard never verifies.**

There is one call site of `verifyIdToken()` in the codebase
([token-verifier.service.ts](../backend/src/common/auth/token-verifier.service.ts)),
and [auth.contract.spec.ts](../backend/src/common/auth/auth.contract.spec.ts)
keeps the layer honest about how identity is consumed.

Verification sits in middleware rather than the guard for three concrete
reasons, each of which would otherwise be a regression:

1. **Rate limiting.** `RateLimitGuard` runs first and keys per-subject rules on
   `auth.uid`. If verification lived in a guard, those limits would key on an
   identity that did not exist yet — and the per-subject rules would stay
   spoofable forever.
2. **The access log.** Rejected requests are the ones worth investigating. Had
   verification lived in the guard, a 401'd request would carry no identity.
3. **One answer to "who is this?"** Every consumer reads `req.auth`. A component
   that needed identity and could not reach the result is exactly how a second
   verification gets added.

### 1.3 Guard ordering — load-bearing

`RateLimitModule` is imported **before** `AuthModule` in
[app.module.ts](../backend/src/app.module.ts), because multiple `APP_GUARD`
providers execute in registration order. Cheap rejection first: a flood of
unauthenticated requests is absorbed by the counter check, never reaching
identity handling. This mirrors the existing decision to run the rate limiter
ahead of `AdminAuthGuard`.

`AuthModule` is imported **before** `IdentityModule`, because middleware resolves
its dependencies from `AppModule`'s injector.

### 1.4 Identity binding

Three cases, per [identity-binding.ts](../backend/src/common/auth/identity-binding.ts):

| Field state | Action | Enforcing | Not enforcing |
|---|---|---|---|
| absent | **inject** verified uid | ✅ | ✅ (when authenticated) |
| `== uid` | pass through | ✅ | ✅ |
| `!= uid` | **conflict** | 403 | **corrected** to uid + warn |

The last row is why `monitor` is a security improvement rather than a purely
diagnostic stage: a caller holding a valid token **cannot act as someone else
even before enforcement is switched on**.

Bindings are declared **per route**, never inferred from field names. The reason
is concrete: `SelectProviderDto` carries both `client_user_id` (the caller) and
`provider_id` (the person being selected). A `/user_id$/` convention would have
bound the wrong one and let anyone assign any open job to themselves — an
authorization hole created *by* the authorization layer. Pinned by test.

---

## 2. Migration plan

### 2.1 Stages

```
   Stage 0            Stage 1                Stage 2               Stage 3
   TODAY              DEPLOYED NOW           CLIENT ROLLOUT        FINAL
   ───────            ────────────           ──────────────        ─────
   no auth      →     AUTH_ENFORCEMENT  →    app update ships  →   AUTH_ENFORCEMENT
                      =monitor               (sends the token)     =enforce

   old client         old client ✅          old client ✅         old client ❌
                      new client ✅          new client ✅         new client ✅
                      ── measuring ──        ── draining ──        ── enforced ──
```

Nothing between Stage 1 and Stage 3 changes a response. The only deploy is the
backend (once) and the app (once). **Stage 3 is an environment variable and a
restart — not a redeploy.**

### 2.2 The readiness gate

Do not advance to Stage 3 on a calendar. Advance on a number:

```
count(access_log where authWouldDeny is set) group by route
```

`authWouldDeny` is set on **exactly** the requests enforcement will reject. When
it reaches ~0 per route, the fleet has updated. While it is non-zero, the routes
listed are the ones that would break, named individually.

Confirmed live:

```
POST /jobs/approve 404 userId=victim ... userIdSource=asserted
    rateLimitPolicy=jobs:action authScheme=firebase authWouldDeny=absent
```

`authScheme` = what the route requires · `userIdSource` = what the caller
proved · `authWouldDeny` = the verdict enforcement would reach.

### 2.3 Graduated enforcement

Risk is not evenly spread. `AUTH_ENFORCE_ONLY` narrows enforcement to a subset
while everything else stays in monitor behaviour:

```bash
AUTH_ENFORCEMENT=enforce
AUTH_ENFORCE_ONLY=/mpesa,/jobs,POST /reviews    # money first
```

Setting it without `AUTH_ENFORCEMENT=enforce` **fails the boot**, rather than
silently doing nothing — the failure mode where a team believes payments are
enforced and nothing is.

### 2.4 Boot refusal

`RouteAuditService` walks every route at boot. Findings are loud errors in
`off`/`monitor` and **fatal in `enforce`**. Enforcement cannot be switched on
over an incomplete auth topology — a system that looks locked down and is not is
worse than one that visibly is not. Verified live in both directions (§7.3).

---

## 3. Endpoint classification

**104 routes — 21 public, 39 Firebase, 44 admin, 0 undeclared.**
Generated from the code; the boot log prints the public surface in full every
start.

### 3.1 PUBLIC (21) — no identity required

| Endpoint | Binding | Why public |
|---|---|---|
| `GET /` | — | Render's default health check points here |
| `GET /health` | — | Orchestrator liveness **and** the app's connectivity probe — neither holds a token. A health check that needs credentials is not a health check |
| `GET /health/database`, `/redis`, `/firebase` | — | Monitoring probes; status only |
| `GET /health/events` | — | Queue depth and timestamps, never event payloads |
| `GET /feed` | `query.user_id` | **Anonymous browsing is the product's front door.** Bound so a signed-in user can't be handed someone else's personalised ranking |
| `GET /promotions/slots` | — | Served alongside the anonymous feed |
| `GET /promotions/packages` | — | Public pricing, shown before sign-up |
| `POST /promotions/events` | — | Impressions originate from the anonymous feed — see §4.4 |
| `GET /reputation/:providerId` | — | Public provider profile, read before deciding to sign up |
| `GET /reviews/provider/:providerId` | — | Same |
| `POST /mpesa/stk-callback` | — | **Daraja posts unauthenticated.** Rejecting a genuine callback = money taken with no job funded |
| `POST /mpesa/b2c-callback` | — | Same |
| `POST /mpesa/b2c-status-result` | — | Same |
| `GET /mpesa/health` | — | Config echo, all secrets masked; audience is an operator |
| `POST /jobs/dispute` | — | Removed endpoint; answers 410 unconditionally, reads no state |
| `GET /admin/_diag` | — | **Bootstrap paradox** — see below |
| `GET /admin/invite/:token` | — | ↓ |
| `POST /admin/accept-invite` | — | ↓ |
| `POST /admin/session/restore` | — | These are how an admin *obtains* a token, so none can require one. Authorization is the single-use invite token, or a Supabase session the backend verifies independently |

### 3.2 AUTH REQUIRED (39) — verified Firebase identity

**Money**

| Endpoint | Binding | Why |
|---|---|---|
| `POST /mpesa/initiate` | `body.buyer_user_id` | Pushes a PIN prompt to the payer's phone. Unbound = make someone else's phone ask them to pay |
| `POST /promotions/campaigns/:id/pay` | `body.user_id` | Same, for campaign purchase |
| `GET /mpesa/status/:postId` | — | Payment state is private to the participants |
| `GET /promotions/campaigns/:id/payment-status` | `query.user_id` | Own payment only |
| `GET /promotions/payments` | `query.user_id` | Own payment history |

**Job lifecycle / escrow**

| Endpoint | Binding | Why |
|---|---|---|
| `POST /jobs/approve` | `body.client_user_id` | **Highest-value binding on the API** — emits `payment.payout_requested`, releasing escrow |
| `POST /jobs/mark-complete` | `body.provider_user_id` | Gates the release request |
| `POST /jobs/select-provider` | `body.client_user_id` | ⚠️ `provider_id` deliberately **not** bound |
| `POST /jobs/notify-application` | `body.applicant_user_id` | Unbound = push-notification injector |
| `POST /jobs/:postId/archive` | `body.user_id` | Author-only soft delete |
| `GET /jobs/:postId/lifecycle` | `query.user_id` | Full payment + dispute history for one participant |
| `GET /jobs/:postId/status` | — | Completion state, private to the two parties |

**Messaging, reviews, disputes**

| Endpoint | Binding | Why |
|---|---|---|
| `POST /notifications/chat-message` | `body.senderId` | The one route whose abuse lands on a **third party** — fires FCM at another person's phone |
| `POST /reviews` | `body.client_id` | ⚠️ field is `client_id`, not `user_id` — see §4.1 |
| `GET /reviews/eligibility/:postId` | `query.user_id` | |
| `POST /disputes/create` | `body.raised_by_user_id` | Freezes escrow, starts an SLA clock that pages a human |
| `GET /disputes/:id/thread` | `query.user_id` | Case file + signed evidence URLs |
| `POST /disputes/:id/reply` | `body.user_id` | Authorship is evidence an arbitrator weighs |
| `POST /disputes/:id/evidence/upload-url` | `body.user_id` | Hands out a **write capability** that outlives the request |
| `POST /disputes/:id/evidence/submit` | `body.user_id` | |

**Promotions (owner surface)** — `createCampaign`, `listCampaigns`,
`getCampaign`, `pause`, `resume`, `cancel`, `analytics`: all bound to
`user_id`. `requireUserId()` keeps working unchanged — the guard has already
injected the field it looks for.

**Feed writes** — `POST /feed/interactions` (`body.user_id`): behavioural events
feed the ranking engine, so an unbound id writes into another person's profile.
`POST /feed/availability` (`body.user_id`): ranking signal on the caller's own profile.

**Other** — `POST /routes/compute`: the one endpoint that spends real money per
call; a journey only exists after a job is funded, so every legitimate caller is
signed in. `/dev/*`, `/mpesa/dev/*`, `/mpesa/test-stk`: depth behind the
production check, not instead of it. `/providers/*`: see §4.2.

### 3.3 ADMIN (44) — opaque Help24 token via `AdminAuthGuard`

All 44 verified guarded at boot. Includes `POST /mpesa/release-payout`, moved
from *unauthenticated* to admin-only (§4.3), and the entire `/admin/events`
surface (§4.5).

---

## 4. Security audit

### 4.1 Attempted bypasses

| Attack | Before | After (enforce) |
|---|---|---|
| **Forged user ID** — `client_user_id: <victim>` to approve their job and release escrow | ✅ **worked** | 403 `IDENTITY_CONFLICT`, or the field is overwritten with the verified uid |
| **Forged provider ID** — self-assign to an open job via `provider_id` | ✅ worked | Blocked by the ownership check, now trustworthy. `provider_id` deliberately unbound so binding cannot *create* this hole |
| **Impersonated sender** — push a chat notification as either party | ✅ worked | Bound to `senderId` |
| **Reputation farming** — reviews as an arbitrary reviewer | ✅ worked | Bound to `client_id` |
| **Escrow freeze** — dispute on a stranger's job | ✅ worked | Bound to `raised_by_user_id` |
| **Expired token** | n/a | 401 `TOKEN_EXPIRED` — client refreshes and replays once |
| **Replayed token** | n/a | Accepted until `exp` (≤1h). Documented trade — §4.6 |
| **Forged/foreign token** | n/a | Signature check fails → 401 `TOKEN_INVALID`. Cannot enter the cache (only verified tokens do) |
| **Missing claims** | n/a | `verifyIdToken` enforces `iss`/`aud`/`sub`/`exp` against the project |
| **Privilege escalation to admin** | n/a | Firebase tokens are never admin credentials; `@AdminAuth()` routes require the opaque token and the audit proves the guard is applied |
| **Middleware-ordering bypass** | n/a | Order asserted in `app.module.ts` with reasoning; guard fails closed on undeclared routes |
| **Undeclared new endpoint** | unprotected | 401 by default + boot audit + build-time contract test |
| **Background jobs** | n/a | Not HTTP; guard returns early. They reach the DB via the service-role key by design |
| **Firebase outage → mass sign-out** | n/a | 503 `AUTH_UNAVAILABLE`, never 401 — §4.7 |

### 4.2 🔴 OPEN — `providers.*` has no ownership model

**Not fixed, and deliberately not fixed here.**

`POST /providers/change-payout` writes the new payout number **first**, then
issues the OTP **to that new number**. A caller who knows a provider UUID can
point payouts at their own phone and verify it themselves. There is no
authorization check of any kind — `providers.id` is a table UUID with **no
column linking it to a user**, so there is nothing for `@Auth` to bind.

`@Auth()` narrows the attacker set from "anyone on the internet" to "anyone with
a Help24 account" and no further.

**Why it is not currently exploitable for money:** the subsystem is orphaned.
`providers.phone_payout` is written by this service and read by **nothing** in
the B2C payout path, and the mobile app never calls these routes.

**Why it is not fixed here:** closing it requires an owner column and a check —
a schema change, not an authentication change. This migration's promise is that
no business logic changes shape. **Highest-priority follow-up.** The moment
anything wires `providers.phone_payout` into a payout, this becomes critical.

### 4.3 ✅ FIXED — `POST /mpesa/release-payout` was unauthenticated

Body carries only `post_id`, so there was no caller to bind — anyone who knew a
post id could request its escrow be paid out. Now `@UseGuards(AdminAuthGuard)`.

Nothing legitimate is lost: the normal payout path is the
`payment.payout_requested` event calling `MpesaService.releasePayout` in-process,
which never touches this route. The app declares a constant for it that no code
path uses.

### 4.4 🟡 ACCEPTED — `POST /promotions/events` unauthenticated ingest

`viewer_user_id` sits inside a nested event array and cannot be bound to a single
field. Requiring a token would stop counting the impressions merchants pay for,
since they originate from the anonymous feed.

Bounded by `telemetry:ingest` (30 burst / 20 per min per subject, 400/240 per
IP). Residual risk: analytics inflation, not authorization. Accepted.

### 4.5 ✅ FIXED (P0) — `/admin/events/*` had no guard at all

[events-admin.controller.ts](../backend/src/events/events-admin.controller.ts)
shipped to production with `@RateLimit('admin:api')` and **no
`@UseGuards(AdminAuthGuard)`**. Despite the `/admin` prefix. Despite every other
admin controller having it.

| Route | Exposure |
|---|---|
| `GET /admin/events` | Full event log **with payloads** — user ids, post ids, amounts, phone numbers |
| `GET /admin/events/:id`, `/dead-letter` | Same |
| `POST /admin/events/replay` | **Re-runs any event handler by id — including `payment.payout_requested`, which initiates an M-Pesa B2C transfer** |

Unrelated to this migration; found while mapping the request path. One missing
line, in a file that otherwise read exactly like its neighbours, with no runtime
signal — the endpoint worked perfectly.

Fixed, **and** the class of bug is now caught mechanically:
`RouteAuditService` cross-checks `@AdminAuth()` against the guards actually
applied on every boot, and refuses to start under `enforce` when they disagree.
[route-audit.spec.ts](../backend/src/common/auth/route-audit.spec.ts) pins the
exact shape as it shipped.

### 4.6 Accepted: no revocation check

`checkRevoked` is not enabled. It forces a network call to Firebase on **every
request**, making this API's latency and availability a function of Firebase's.

Trade: a revoked session stays usable until its token expires (≤1 hour). For a
marketplace where destructive actions all require an ownership match against a
resource, that window is acceptable. **The verified-token cache does not widen
it** — entry lifetime is capped at both the TTL ceiling and the token's own
`exp`, so a cached identity can never outlive its credential.

### 4.7 The distinction that prevents a mass sign-out

If Google's key endpoint is unreachable, `verifyIdToken` throws. A naive
classifier calls that an invalid token, answers 401, and every signed-in user is
told their session is bad — simultaneously, over an outage none of them caused,
and many will re-authenticate rather than wait.

`classify()` separates transport/key-fetch failures (`unavailable` → **503**)
from credential failures (**401**). Nine cases pinned in
[token-verifier.spec.ts](../backend/src/common/auth/token-verifier.spec.ts).

### 4.8 Error contract

| Code | Status | Client action |
|---|---|---|
| `AUTH_REQUIRED` | 401 | Prompt sign-in |
| `TOKEN_EXPIRED` | 401 | **Refresh and replay once** (automatic) |
| `TOKEN_INVALID` / `TOKEN_REVOKED` | 401 | Session is dead — sign out |
| `IDENTITY_CONFLICT` | 403 | Bug or attack; do not retry |
| `AUTH_UNAVAILABLE` | 503 | Back off and retry — **never sign out** |

### 4.9 Defence in depth added along the way

- `POST /mpesa/test-stk` — was unauthenticated, reachable in production, and
  pushed an STK prompt to **any phone number in the body**. Now requires
  authentication **and** is blocked when `MPESA_ENV=production`, matching the
  other dev routes. Authentication alone would have narrowed the attacker set to
  "anyone with an account", which for a free app is not a meaningful bound.
- Cache keys are SHA-256 digests, never raw tokens — a heap dump or an
  accidental log of the cache cannot yield a working credential.
- `IdentityMiddleware` skips `/admin` paths, so admin tokens are never fed to
  Firebase (no wasted signature checks, no polluted failure counters).

---

## 5. Performance

Measured on this machine against the compiled build. Benchmarks are real code,
not estimates.

### 5.1 Guard overhead — per request

| Path | µs/op | ops/s |
|---|---:|---:|
| Admin route (guard stands down) | 0.775 | 1,289,910 |
| Public route, no bindings | 0.987 | 1,013,023 |
| Protected, authenticated, field matches | 1.021 | 979,848 |
| Public route, optional binding | 1.035 | 965,773 |
| Protected, authenticated, uid injected | 1.100 | 909,400 |

**~1 µs.** Metadata lookup plus at most one object-property write.

### 5.2 Token verification

| Path | µs/op | ops/s |
|---|---:|---:|
| Cache hit (SHA-256 + map lookup) | 2.217 | 451,151 |
| RS256 verify (proxy for `verifyIdToken`, keys cached) | 21.655 | 46,179 |

`verifyIdToken` checks an RS256 signature against Google's signing keys, which
firebase-admin fetches once and caches in-process for ~6 hours. **The steady
state involves no network round trip.** The exceptions — first request after
boot, and key rotation — cost one HTTPS fetch shared across concurrent requests.

### 5.3 Total, and honestly

**~3 µs per request** at a high cache hit rate; **~23 µs** worst case with no
cache at all. Against a 200 ms p95 request budget that is **0.001%**.

**The cache is worth having but is not load-bearing.** At 10,000 concurrent
users polling every 5 s (≈2,000 req/s): uncached ≈43 ms CPU/s (4.3% of one
core), cached ≈4 ms/s (0.4%). Real, not dramatic. `AUTH_TOKEN_CACHE=false`
switches it off with no correctness impact.

Memory: 10,000 entries × ~200 B ≈ **2 MB**, hard-capped with LRU eviction.

### 5.4 Repeated verification — eliminated by construction

One call site of `verifyIdToken`. One verification per request, in middleware.
Every downstream consumer reads `req.auth`. Not a convention — a structural
property, because the guard has no verifier to call.

### 5.5 Scale

Nothing added is per-user state on the server. The cache is per-instance and
bounded; the limiter's Redis state is unchanged. Adding instances adds capacity
linearly — each verifies the tokens it sees and caches them independently.

---

## 6. Compatibility

### 6.1 What the old client does

It sends **no `Authorization` header** to this backend. It mints Firebase tokens
only to exchange for a Supabase session
([supabase_auth_bridge.dart](../mobile-app/lib/services/supabase_auth_bridge.dart)).
So `req.auth` is empty on every real request today.

### 6.2 Guarantees per stage

| Behaviour | `off` | `monitor` | `enforce` |
|---|---|---|---|
| Old client, protected route | ✅ works | ✅ works | ❌ 401 |
| Old client, public route | ✅ | ✅ | ✅ |
| Anonymous Discover browsing | ✅ | ✅ | ✅ |
| Anonymous personalised feed (`user_id` unproven) | honoured | honoured | **dropped** |
| New client | ✅ | ✅ | ✅ |
| Conflicting identity + valid token | corrected | corrected | 403 |
| Response bodies changed | none | none | 401/403 added |
| Log volume | unchanged | +1 sampled warn/route/min | same |

Verified live in `monitor`: `POST /jobs/approve` with no token returned **404
"Post not found"** — the business logic ran, exactly as before.

### 6.3 The one behaviour change at Stage 3

An **anonymous** caller passing `user_id` to `GET /feed` stops getting
personalised results (they get the generic ranked feed). Honouring an unprovable
claim lets anyone read another person's personalisation — what they have been
searching for and applying to. Signed-in users are unaffected: the guard binds
their own uid.

### 6.4 Two tokens, deliberately not merged

| Client | Carries | Verified by |
|---|---|---|
| `HttpClientWithToken` → Supabase | Exchanged **Supabase JWT** | PostgREST RLS |
| `Help24ApiClient` → our backend | Raw **Firebase ID token** | Firebase Admin SDK |

Sending either to the other's server fails. Both are cleared together on
sign-out.

### 6.5 The trap the contract test caught

The global `ValidationPipe` runs with `forbidNonWhitelisted: true`. Guards run
**before** pipes — which is what lets an injected identity be validated and reach
the handler — and it also means injecting a field the DTO does not declare
becomes a **400**.

This was not hypothetical: `getSlots` was initially given
`bind: 'query.viewer_user_id'`, a field that exists on `PromotionEventDto` but
**not** on `SlotsQueryDto`. Every *authenticated* call to `/promotions/slots`
would have 400'd — breaking promoted placements for signed-in users only, and
only once enforcement was switched on. Every anonymous smoke test would have
passed.

[auth.contract.spec.ts](../backend/src/common/auth/auth.contract.spec.ts) now
checks every binding against its DTO's class-validator metadata at build time.

---

## 7. Rollback

### 7.1 Instant — no redeploy

```bash
AUTH_ENFORCEMENT=monitor   # from enforce
# restart
```

Returns to a state where **nothing is rejected** for missing identity. Verified
bindings still apply, so a new client stays protected. This is the primary
rollback and it takes as long as a restart.

### 7.2 Partial

```bash
AUTH_ENFORCE_ONLY=/mpesa   # keep money enforced, relax everything else
```

### 7.3 Full

```bash
AUTH_ENFORCEMENT=off       # pre-migration behaviour, including log volume
```

### 7.4 Code-level

The auth layer is additive: one `common/auth` module plus decorators. Reverting
the commit restores prior behaviour exactly — **except** the three security
fixes, which should be kept:

- `@UseGuards(AdminAuthGuard)` on `EventsAdminController` (§4.5)
- `@UseGuards(AdminAuthGuard)` on `POST /mpesa/release-payout` (§4.3)
- the production gate on `testStk` (§4.9)

None depends on the auth module.

### 7.5 What cannot be rolled back by env var

The client sending an `Authorization` header. It is harmless in every mode — the
server ignores it in `off` — so no client rollback is needed.

---

## 8. QA checklist

### 8.1 Automated — all green

```
Backend    npx jest              469 passed, 15 skipped (Redis integration)
           npx tsc --noEmit      clean
           npx nest build        clean
Mobile     flutter analyze       no errors (69 pre-existing warnings)
           flutter test          655 passed
```

Auth-specific: **124 tests** across `identity-binding`, `auth.guard`,
`auth.config`, `token-verifier`, `route-audit`, `auth.contract`.

### 8.2 Boot verification — done

- [x] Boots in `off`, `monitor`, `enforce`
- [x] Audit reports `104 routes — firebase=39 admin=44 public=21 undeclared=0`
- [x] Prints all 21 public routes with reasons
- [x] Logs `Every route declares a scheme and every admin route is guarded`
- [x] `monitor` banner states enforcement is not active + the readiness test
- [x] **Undeclared route → warns and boots in `monitor`**
- [x] **Undeclared route → refuses to start in `enforce`** (verified by
      temporarily removing a decorator; message names the routes and the fix)
- [x] `AUTH_ENFORCE_ONLY` without `enforce` fails the boot

### 8.3 Live HTTP — done

`monitor`: public 200 · protected reach business logic (404 "Post not found")
· **admin 401**
`enforce`: public 200 · protected **401 + `code`** · admin 401

- [x] `GET /health`, `/`, `/feed`, `/promotions/packages`, `/health/events` → 200 both modes
- [x] `POST /mpesa/stk-callback` → 200 both modes (Daraja must never be rejected)
- [x] `POST /jobs/approve` → 404 in monitor, **401** in enforce
- [x] `POST /jobs/mark-complete`, `/mpesa/initiate`, `/notifications/chat-message`,
      `/routes/compute`, `GET /promotions/campaigns` → 401 in enforce
- [x] Garbage bearer token → 401 (not 500)
- [x] `GET /admin/events`, `POST /admin/events/replay`, `/admin/events/dead-letter`
      → **401 in both modes** (was 200 before)
- [x] `POST /mpesa/release-payout` → **401 in both modes** (was reachable before)
- [x] Error body carries `code: AUTH_REQUIRED`
- [x] Access log shows `authScheme=firebase authWouldDeny=absent`
- [x] Log fields **not** redacted (regression fixed + pinned — §8.6)

### 8.4 Manual — device, before Stage 3

Requires a signed-in build against the deployed backend. **Not yet run.**

**In `monitor`, with the updated app:**
- [ ] Sign in → Discover loads and is personalised
- [ ] Post a job → apply as another account → author gets the notification
- [ ] Select provider → pay (STK) → mark complete → approve → payout
- [ ] Chat both directions; push arrives on the other device
- [ ] Raise a dispute, reply, attach evidence
- [ ] Create a promotion campaign, pay, view analytics
- [ ] Submit a review after completion
- [ ] Journey ETA renders
- [ ] `authWouldDeny` **absent** for the updated app on every flow above
- [ ] Sign out → sign in as a different user → no cross-user data

**Token lifecycle:**
- [ ] Background the app > 1 hour, return, act → succeeds (silent refresh)
- [ ] Airplane mode → clear offline error, not "sign in again"
- [ ] Sign out → backend calls carry no token

**Anonymous:**
- [ ] Fresh install, no sign-in → Discover, provider profiles, reviews, pricing all load
- [ ] Attempting a protected action → prompts sign-in

**Then, in `enforce`:**
- [ ] Repeat every flow above
- [ ] Old app build → protected actions fail with "Sign in again", browsing still works

### 8.5 Rollback drill — before Stage 3

- [ ] `enforce` → `monitor` → restart → old client works within one restart
- [ ] Time the restart; confirm it matches the incident budget

### 8.6 Regression pinned

The three new access-log fields (`authScheme`, `authEnforced`, `authWouldDeny`)
were silently written as `[REDACTED]`, because `redact.ts` substring-matches
`auth`. Nothing errored — **the readiness dashboard was simply blank**, which is
the worst way for an instrument to break. Found by live smoke test.

Fixed with an **exact-match** allowlist (never substring, so `auth` on the list
could not un-redact `authToken`), plus tests asserting `authorization`, `auth`,
`authToken`, `auth_token`, `authSchemeToken` and `userAuthSecret` all still
redact.

---

## 9. Files

**New — `backend/src/common/auth/`**

| File | Purpose |
|---|---|
| `auth.types.ts` | Vocabulary: modes, schemes, failure reasons, error codes |
| `auth.config.ts` | Env parsing, validation, `shouldEnforce()` |
| `auth.decorator.ts` | `@Auth()`, `@Public()`, `@AdminAuth()` |
| `identity-binding.ts` | Pure binding logic — inject / match / conflict / drop |
| `token-verifier.service.ts` | **The only** `verifyIdToken` call site; cache; classification |
| `auth.guard.ts` | Global guard: enforce + bind |
| `route-audit.service.ts` | Boot-time topology check |
| `auth.module.ts`, `auth.tokens.ts` | Wiring |
| 6 × `*.spec.ts` | 124 tests |

**New elsewhere:** `admin/auth/admin-auth.module.ts` (breaks the
`AdminModule ↔ MpesaModule` cycle without `forwardRef`),
`mobile-app/lib/services/api_client.dart`.

**Modified:** `identity.middleware.ts` (delegates to the verifier, records
failure reasons), `app.module.ts` (ordering), `main.ts` (banner),
`request-context.ts` + `access-log.middleware.ts` (three fields),
`redact.ts` (allowlist), 20 controllers (decorators), 11 Dart services
(authenticated client), `error_mapper.dart` (401 ≠ 403).

---

## 10. What to do next

1. **Deploy the backend.** Default `monitor` — no client breaks. The three
   security fixes (§4.3, §4.5, §4.9) take effect immediately and do not wait for
   enforcement.
2. **Ship the app update.** It sends the header; all modes tolerate it.
3. **Watch `authWouldDeny`** by route until ~0.
4. **Run §8.4 and §8.5.**
5. **`AUTH_ENFORCEMENT=enforce`** — optionally via `AUTH_ENFORCE_ONLY=/mpesa,/jobs` first.
6. **Then fix `providers.*` (§4.2)** — the remaining open issue, and a schema
   change rather than an auth one.
