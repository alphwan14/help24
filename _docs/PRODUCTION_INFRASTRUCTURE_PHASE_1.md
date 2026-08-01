# Production Infrastructure — Phase 1

Distributed rate limiting, request correlation, structured logging, health
endpoints, and the Redis infrastructure layer they all sit on.

**Scope discipline:** no feature work, no caching of feeds, no changes to the
recommendation engine. Every existing endpoint keeps its path, its request
shape and its response shape.

---

## 1. Architecture overview

### 1.1 What was added

```
backend/src/
├── redis/                                   ← THE Redis layer. Nothing else talks to Redis.
│   ├── redis.config.ts                      env parsing + validation + credential redaction
│   ├── redis.service.ts                     connection lifecycle, health, shutdown, script exec
│   ├── redis.scripts.ts                     the two Lua scripts (atomic check-and-consume)
│   ├── redis.module.ts                      NOT global — exactly two modules may import it
│   ├── redis.config.spec.ts
│   └── redis-scripts.integration.spec.ts    runs the real Lua against a real server (opt-in)
│
├── common/
│   ├── request-context/                     AsyncLocalStorage — the correlation backbone
│   │   ├── request-context.ts
│   │   ├── request-context.middleware.ts
│   │   └── request-context.spec.ts
│   ├── logging/
│   │   ├── redact.ts                        secret + PII scrubbing
│   │   ├── structured-logger.service.ts     the ONE log writer for the process
│   │   ├── access-log.middleware.ts         one structured line per request
│   │   ├── logging.module.ts
│   │   ├── redact.spec.ts
│   │   └── structured-logger.spec.ts
│   ├── rate-limit/
│   │   ├── rate-limit.types.ts              policy / rule vocabulary
│   │   ├── rate-limit.policies.ts           THE CATALOGUE — every number, with reasoning
│   │   ├── rate-limit.decorator.ts          @RateLimit('name') / @SkipRateLimit()
│   │   ├── rate-limit.service.ts            evaluation engine
│   │   ├── local-rate-limiter.ts            in-process fallback for a Redis outage
│   │   ├── rate-limit.guard.ts              global guard
│   │   ├── rate-limit.module.ts
│   │   └── 4 spec files
│   ├── identity/                            optional, NON-ENFORCING Firebase resolution
│   │   ├── identity.middleware.ts
│   │   └── identity.module.ts
│   └── all-exceptions.filter.ts             (upgraded) requestId + preserved error fields
│
└── health/
    ├── health.types.ts                      healthy | degraded | unavailable + budgets
    ├── health.service.ts                    probes + the snapshot that keeps /health O(1)
    ├── health.controller.ts                 /health, /health/database|redis|firebase
    ├── health.module.ts
    └── health.service.spec.ts
```

Deleted: `src/health.controller.ts` (superseded by `src/health/`; both response
shapes preserved byte-for-byte in the healthy case).

### 1.2 How Redis is used

**Redis stores exactly one thing: rate-limit counters.** No feed cache, no
session store, no queue. That restraint is the design — a general-purpose
`RedisService.get/set` would invite the scattered usage this layer exists to
prevent, and Phase 1 is infrastructure, not optimisation.

Two data structures, chosen per endpoint:

| Structure | Used for | Why |
|---|---|---|
| **Sorted set** (sliding window log) | OTP verify, STK push, payout release, admin auth, disputes, uploads | Exact. A fixed window allows double the limit across its boundary — for "5 OTP attempts per 15 minutes" that is the difference between a limit and a suggestion. Memory is O(n) per key, and n is single digits here. |
| **Hash** (token bucket) | feed, job status, payment polling, telemetry, chat notify, admin API | O(1) memory, burst-tolerant. Opening a screen in the app fires several requests at once; a flat per-minute cap would reject the legitimate cold-start burst while still permitting an attacker to sit exactly on the line forever. A bucket absorbs the burst and constrains the sustained rate — which is the actual distinction between a person and a script. |

Key shape:

```
help24:<NODE_ENV>:rl:<policy>:<rule>:<sha256(identity)[0..16]>
```

- The **environment prefix** stops a staging load test consuming production
  budget when two deployments share one Redis instance.
- The identity is **hashed**. Redis is a lower-trust store than the database;
  without hashing, `KEYS *` from anyone with access would enumerate user IDs
  and IP addresses. Hashing also bounds key length whatever a caller puts in a
  `user_id` field.
- Every key carries a **TTL**, so abandoned identities evict themselves and
  memory is bounded by active traffic rather than by lifetime traffic.

### 1.3 The property that makes it correct across replicas

Check-and-consume happens **inside a single Lua script**, which Redis executes
atomically — no other command from any connection can interleave. There is no
read-decide-write window for a second instance to race with.

This is the whole point. The previous in-process limiter in `routes.service.ts`
was correct for exactly one replica and silently multiplied by the replica
count thereafter: at two instances the real ceiling was 80 per 10 minutes, at
five it was 200, and nothing anywhere said so.

Two further details that only matter once there is more than one instance:

- **The clock comes from Redis** (`redis.call('TIME')`), not from Node. Container
  clocks drift; a replica running two seconds fast would evict another
  replica's still-valid window entries and hand out extra budget. One clock
  removes the entire class of problem.
- **`redis.replicate_commands()`** is called before the first write. Required on
  Redis 5/6 for a script that reads `TIME` then writes; a no-op on 7+. The
  service logs the server version at connect and shouts if it is below 5.

### 1.4 Failure behaviour — the central decision

**A sick Redis degrades the API. It never stops it.** Every option in
`redis.service.ts` serves that one property:

| Setting | Why |
|---|---|
| `enableOfflineQueue: false` | The most consequential line in the file. ioredis defaults to queueing commands while disconnected and flushing on reconnect. For a cache that is a kindness; for a rate limiter on the request path it is a disaster — every request would block until the connection recovers, turning a Redis outage into an API outage. Off, a command against a dead connection rejects in microseconds. |
| `commandTimeout: 250ms` | Bounds a connection that is up but unresponsive, which offline-queue rejection does not cover. A rate-limit check slower than a quarter-second has already failed at its job, which is to be invisible. |
| `lazyConnect` + event-driven readiness wait | A Redis that is down at boot produces a warning, not a crash loop. |
| `maxRetriesPerRequest: 1` | One retry absorbs a dropped packet; more just multiplies latency on a dependency that is already failing. |
| Jittered exponential backoff | A Redis restarting under load must not be met by every backend instance reconnecting at the same millisecond. |

When Redis cannot answer, the limiter falls back to `LocalRateLimiter`, an
in-process implementation of the same two algorithms.

**The honest bound this provides:** state lives in one process, so with N
instances the effective ceiling becomes `limit × N`. At today's single instance
that is exactly the configured limit. At three instances, an OTP verify limit
of 5/15min becomes 15/15min — still bounded, still nowhere near brute-forcing a
6-digit code, and vastly better than unlimited. State is also lost on restart.

That is the entire guarantee, written down so nobody reads "fail open" and
assumes either extreme. Degradation is announced three ways: a `WARN` log
(throttled to once per 30s with a count), a `RateLimit-Degraded: true` response
header, and `GET /health/redis`.

### 1.5 Request correlation

`AsyncLocalStorage`, entered once per request by the first middleware.

The alternative — threading a context argument through every method — would
mean editing the signature of essentially every function in the codebase and
would still lose the ID wherever someone forgot to pass it. ALS propagates
through promises, timers and callbacks automatically, so **the ~30 services that
already call `this.logger.log(...)` gained correlation without a single line
changing in any of them.** Correlation had to be free at the call site or it
would only ever be applied to the code someone remembered.

Because `next()` is called inside `store.run(...)`, everything downstream —
routing, guards, the handler, interceptors, the exception filter, and any
fire-and-forget work a handler spawns — inherits the same store.

Inbound `X-Request-Id` is honoured so a trace begun on the device stays one
trace, but it is **sanitised first** (`[A-Za-z0-9._:-]{8,128}`). An unvalidated
value echoed into logs and a response header is a log-injection and
header-injection vector. A rejected ID does not fail the request; the caller
simply does not get to choose its name. The ID grants no authority of any kind.

### 1.6 Structured logging

`StructuredLogger` is installed via `app.useLogger()`, so it replaces the
output of Nest's own logs **and** every existing `new Logger(X)` call site at
once. Rewriting those by hand would have been a large, risky diff that touched
business logic to change observability.

Access logs are emitted from **middleware on `res.on('finish')`**, not from an
interceptor. An interceptor only sees requests that reach a handler — it never
sees 404s (no route matched), 401/403 (a guard rejected first), 429 (the rate
limit guard runs first), or 400 from the global `ValidationPipe`. That list is
most of what an operator investigates. `close` is handled too, so a phone that
leaves coverage mid-response still produces a line.

Every access line carries: `timestamp, requestId, method, endpoint, route,
status, latencyMs, ip, userAgent, userId, userIdSource, rateLimitPolicy,
rateLimited`.

`route` is the Express pattern (`/jobs/:postId/status`) alongside the concrete
path, because `/jobs/<uuid>/status` produces a distinct series per job in a log
platform and is useless for spotting a spike.

**Severity has one deliberate exception:** a *successful* `GET /health` logs at
`debug` (off by default). The app polls it as its connectivity probe every ten
seconds per device, so at real user counts it would be the overwhelming
majority of log volume. A *failing* probe keeps its normal severity.

**Redaction is structural, not a convention.** Two mechanisms, because there
are two shapes of log: `redactObject()` matches on key name (`password`,
`secret`, `token`, `otp`, `passkey`, `authorization`, …); `redactText()`
matches on value shape (`Bearer …`, JWTs, `"password":"…"` inside an
already-serialised string, and Kenyan MSISDNs). The second exists because the
M-Pesa callback handlers log `JSON.stringify(body)` — the object is gone before
a logger sees it.

Verified live: the smoke run below logged `[TEST-STK] endpoint called —
phone=254712345678` from untouched controller code, and the phone number
appears **zero** times in the resulting log file.

### 1.7 Health endpoints

| Endpoint | Probe | Status codes |
|---|---|---|
| `GET /health` | none — returns a background-refreshed snapshot | **always 200** |
| `GET /health/database` | `select id from posts limit 1`, with a real `AbortSignal` | 200 healthy/degraded, 503 unavailable |
| `GET /health/redis` | `PING` | 200 healthy/degraded, 503 unavailable |
| `GET /health/firebase` | the service-account credential mints an access token | 200 healthy/degraded, 503 unavailable |

**Why `/health` never returns 503.** Two different questions get asked of a
health endpoint and they want opposite answers: *liveness* ("is this process
wedged — restart it?") and *dependency* ("is Supabase reachable — page
someone?"). Conflating them turns a small incident into a large one: a 503
while Supabase is slow would make Docker's HEALTHCHECK mark the container
unhealthy and Render pull it from rotation, restarting a perfectly good process
for a fault a restart cannot fix. Worse here than most systems, because the
Flutter app polls this same endpoint — a 503 makes every device display "you
are offline" while the phone's connection is fine.

**Why `/health` never probes inline.** If Supabase hangs, a probing `/health`
would exceed the app's 5-second timeout and every device in the country would
simultaneously decide it has no internet. A background task (`PeriodicTask`,
reused from the existing sweeps) refreshes a snapshot every 15s; the endpoint
returns it. Latency is independent of every dependency's.

The deep endpoints DO probe live, and are **single-flight**: fifty concurrent
monitor calls produce one query. Without that, the cheapest way to load the
database would be to repeatedly ask whether the database is loaded.

`/health` is the only route exempt from rate limiting, because the check costs
a Redis round trip and the response costs a property read — limiting it would
make the check more expensive than the thing it protects, and would risk 429ing
the connectivity probe of every device behind one carrier NAT.

Firebase's probe is deliberately deeper than "is the object non-null?": a
malformed private key, a revoked service account or a disabled project all
produce a perfectly healthy-looking `App` that fails on the first push. Minting
a token exercises the credential end to end. The SDK caches it for ~1 hour, so
the network cost is paid roughly hourly, not per probe.

### 1.8 How limits are bound to endpoints

`@RateLimit('policy-name')` on the handler or controller. The decorator carries
**no numbers** — only a reference into the catalogue.

- Retuning a limit is a one-line edit in `rate-limit.policies.ts` and needs no
  knowledge of which controllers use it.
- Moving an endpoint between controllers cannot lose or change its protection,
  which a central `{ 'POST /path': 'policy' }` table could not guarantee — a
  renamed route would silently drop its limit with nothing failing.
- An unknown policy name **throws at module load**, not on the first request.

A permissive `default` policy applies to any route without a decorator, so the
failure mode is "this limit is looser than it should be" (visible in the
catalogue) rather than "this endpoint has no limit" (invisible until exploited).

**53 decorators across 17 controllers. Every controller is covered.** The one
without a decorator — `routes.controller.ts` — is intentional and commented:
its limit is applied *inside* the service, after the cache lookup, because only
a cache miss reaches Google and costs money. It still carries the `default`
policy as an outer backstop, so it has two limits, not none.

---

## 2. Security improvements

### 2.1 Vulnerabilities now prevented

**1. Payout OTP brute force — the most serious one closed.**
`POST /providers/verify-payout` had **no rate limit of any kind**. A payout OTP
is 6 digits, valid for 5 minutes. At even 200 requests/second the entire
keyspace is exhaustible inside the validity window, and the prize is control of
where a provider's money is sent. Now 5 attempts per 15 minutes per provider
**and** 30/hour per IP. The IP rule is the one that matters, because
`provider_id` comes from the request body and can be rotated; together they cut
the reachable keyspace to a few hundred guesses per hour per host — roughly a
0.03% chance of hitting a live code before it expires.

**2. STK-push spam and phone harassment.** `POST /mpesa/initiate` was unlimited;
every call pushes a PIN prompt onto a real phone and burns Daraja quota. Now
5 per 10 min per payer, 60 per 10 min per IP.

**3. Unauthenticated STK push to an arbitrary number.** `POST /mpesa/test-stk`
takes a phone number from the body, is unauthenticated, and is reachable in
production — a harassment tool and a quota burner. Now 3/hour per IP. **This
contains it; it does not fix it.** See §4.

**4. OTP issuance as an SMS pump.** `providers/register` and `change-payout`
each mint an OTP and (once an SMS provider is wired in) send a paid text. Also
an availability attack: issuing expires the previous code, so unlimited
issuance would permanently deny a provider the ability to verify. Now 3/hour
per subject, 10/hour per IP.

**5. Admin invite-token enumeration.** `GET /admin/invite/:token` is a validity
oracle — it answers whether a token is valid. Unlimited, it is enumerable, and
an admin account resolves disputes and moves money. Now 10/min **and** 60/hour
per IP: the minute rule stops a fast script, the hour rule stops a slow one
staying under it.

**6. Admin credential brute force against the database.** The global guard runs
**before** `AdminAuthGuard`, so an invalid token is now rejected by a cheap
Redis check before it reaches a database lookup — brute-forcing can no longer
be converted into a database load problem.

**7. Signed-upload-URL abuse.** `POST /disputes/:id/evidence/upload-url` issues
write capabilities into a private bucket that outlive the request; the cost of
abuse lands later as storage. Now 20/hour per subject at cost 2.

**8. Notification-driven harassment and FCM quota burn.**
`POST /notifications/chat-message` fires a push at another person's phone.
Now 40 burst / 30 per minute per sender.

**9. Arbitration-queue flooding.** `POST /disputes/create` freezes an escrow
transaction and starts an SLA clock that pages a human — a denial-of-service
against the operations team rather than the server. Now 5/hour per subject.

**10. Google Routes billing abuse across replicas.** The existing 40/10min cap
was per-process; it now holds across the whole deployment.

**11. Ranking-signal pollution.** `POST /feed/interactions` writes behavioural
events that feed the recommendation engine, unauthenticated. Now bounded.

**12. Credential and PII leakage into logs.** Bearer tokens, JWTs, passwords,
`otp_code`, M-Pesa secrets and customer phone numbers are scrubbed from all log
output — including from `JSON.stringify(body)` calls in existing handlers that
were never changed.

**13. Log injection and header injection via `X-Request-Id`.** Sanitised.

**14. Health endpoints as an amplification vector.** Single-flight coalescing
plus a 60/min limit.

**15. Memory exhaustion during a Redis outage.** An attacker rotating
identities creates one fallback key per request; an unbounded map would turn a
Redis incident into an OOM crash. The fallback sweeps and hard-caps at 50k keys.

**16. Eviction-triggered limit bypass.** `maxmemory-policy noeviction` is now
justified for the limiter too: under LRU, Redis could silently evict a counter
still inside its window and the next request would start from a full budget.

**17. Denied-request expiry bypass.** In the token bucket, `PEXPIRE` runs on the
denied path as well. Without it, a caller hammering a drained bucket would let
the key expire mid-attack and the next request would start from a **full**
bucket — a complete bypass for anyone who simply does not back off. Covered by
an integration test.

### 2.2 Found and NOT fixed — out of this phase's scope

These are real and are documented rather than silently carried. **Items A and B
are, in my assessment, more serious than anything this phase fixed.**

**A. There is no authentication on any user-facing endpoint.**
The backend never verifies a Firebase or Supabase token. Identity travels in
the request body (`buyer_user_id`, `user_id`, `senderId`) and is trusted. Any
person on the internet who knows a user ID can act as that user: initiate their
payments, approve their jobs, read their dispute threads, send notifications as
them. The mobile app sends an `Authorization` header **only to Supabase**, never
to this backend.

Not fixed here because enforcement would 401 every request from every shipped
client and requires a coordinated app release. `IdentityMiddleware` is the seam
it will hang on: it verifies a Firebase ID token when present, attaches the
result, and rejects nothing. Every per-subject policy already lists `auth.uid`
first, so the moment the app sends tokens, subject limits become unspoofable
with no further code change.

**B. M-Pesa callbacks are unauthenticated and unverified.**
`POST /mpesa/stk-callback`, `/b2c-callback` and `/b2c-status-result` accept any
JSON from anyone. There is no source-IP allowlist, no shared secret, and no
confirmation call back to Daraja. Someone who guesses or observes a
`CheckoutRequestID` can forge a "payment succeeded" callback and have a job
funded without money moving. The rate limit here is deliberately the loosest in
the catalogue (dropping a genuine callback means a payment that never settles),
so it provides essentially no protection against this. Fixing it needs a
Safaricom IP allowlist plus a Transaction Status confirmation before settling.

**C. `POST /mpesa/release-payout` takes only `post_id`.**
Unauthenticated, and it triggers a B2C payout. The service checks transaction
state (`paid` → `payout_pending`) and rejects double release with a 409, which
is what currently prevents loss. The new 5/hour-per-post limit is depth over
that guard, not a replacement. **Recommendation: require admin auth or a
verified participant identity.**

**D. `POST /mpesa/test-stk` should not exist in production.**
Rate limited to 3/hour per IP, but the right fix is the same production gate
the `/mpesa/dev/*` routes already use. Left alone because gating an endpoint is
a behaviour change beyond this phase; the recommendation is recorded in the
controller itself.

**E. The highest-value abuse surfaces do not pass through this backend.**
Post creation, job applications and chat messages are written **client-side
directly to Supabase**. This backend only receives the notification hook
afterwards. Nothing in this phase can rate-limit post spam or application spam,
because those requests never arrive here. That has to be enforced in Postgres —
RLS policies plus a per-user insert-rate trigger, or by moving those writes
behind the API.

**F. Per-subject limits are advisory until (A) is fixed.** An attacker who
rotates `user_id` escapes every subject rule and meets only the IP rule. The
subject rules are still worth having — they stop the failure that happens far
more often than a determined attacker: a buggy client release, a retry loop, a
user hammering a button.

**G. CGNAT makes IP limits blunt.** Kenyan carriers put many subscribers behind
one public IPv4 address. Every IP rule here is sized for a crowd, which means
it is a poor instrument against a single determined attacker on a mobile
connection. Proper per-user limits require (A).

**H. `GET /admin/_diag` leaks token metadata** (length, hash prefix, and the
admin's email and role for a valid token). Gated behind `ADMIN_AUTH_DEBUG`, and
it is now rate limited by `admin:auth`, but it should be deleted.

---

## 3. Scalability improvements

**What now works correctly with multiple backend instances:**

| Concern | Before | After |
|---|---|---|
| Google Routes spend cap | 40/10min **per process** — silently ×N with N replicas | 40/10min for the whole deployment |
| Every other rate limit | did not exist | one budget across all replicas, atomic |
| Request tracing | impossible across instances | one `X-Request-Id` reconstructs a request wherever it ran |
| Log aggregation | free-text, per-instance | one JSON schema; `requestId`, `userId`, `route`, `status`, `latencyMs` are queryable fields |
| Dependency visibility | `/health` returned a constant | three real probes, three-state, per-dependency latency |
| Clock consistency | n/a | limits use the Redis server clock, immune to per-container drift |
| Environment isolation | n/a | keys namespaced by `NODE_ENV`; staging cannot spend production budget |
| Redis failover | n/a | `READONLY` triggers reconnect; jittered backoff prevents thundering-herd reconnects |
| Graceful shutdown | HTTP + sweeps drained | Redis connection now drains too, on `onApplicationShutdown` (after every module's destroy hook, so a draining sweep is not cut off) |

**Cost per request:** one Redis round trip per rule, evaluated sequentially with
short-circuit on the first denial. Typical policy = 2 rules ≈ 2 round trips
(single-digit milliseconds same-region). Rules are ordered subject-before-IP so
a heavy individual exhausts their own budget before spending the shared IP
budget everyone behind the same NAT depends on.

**A trade-off stated plainly:** because evaluation consumes budget as it
proceeds, a request denied by rule 2 has already spent one unit of rule 1.
Making all rules atomic together would need one script over multiple keys with
mixed algorithms — a significant complexity increase to avoid over-consuming a
single unit on requests that are being rejected anyway.

**What is NOT solved:** the three background sweeps (event retry, promotions
lifecycle, dispute SLA) have no distributed lock. With N replicas, **all N run
every sweep**. `PeriodicTask` prevents overlap *within* a process, not across
processes. This is the next thing that breaks when you scale, and Redis is now
in place to fix it with a `SET NX PX` leader lock. It is not in this phase
because it changes background-job behaviour, not infrastructure.

---

## 4. Remaining weaknesses — an honest list

**Not verified in my environment (highest priority to confirm):**

1. **The Lua scripts have not been executed against a live Redis here.** Redis
   in WSL was bound to its own loopback and unreachable from Windows; the
   Docker daemon was not running. The integration suite is written and skips
   itself unless `REDIS_TEST_URL` is set — a suite that silently passes when its
   dependency is missing is worse than none. **QA §1 is the first thing to run.**
   Everything else was verified live against a running server (see §5).

2. **`docker compose up` was not executed.** The compose file passes
   `docker compose config` validation, but the stack was not started.

**Design limitations, accepted deliberately:**

3. **Fail-open means `limit × instances` during a Redis outage.** No policy
   ships fail-closed; the lever exists (`failOpen: false`) and is tested.

4. **The fallback loses state on restart.** A crash-looping instance resets its
   local counters each time.

5. **Sequential rule evaluation over-consumes by at most one unit** on denied
   requests (see §3).

6. **`admin:api` is keyed on IP**, because the global guard runs before
   `AdminAuthGuard` and the admin identity is not yet resolved. Fine for a small
   internal team; needs revisiting if many admins share one office NAT.

7. **Rate limits are not adaptive.** No automatic tightening under load, no
   per-account reputation, no ban list. A determined attacker rotating IPs is
   limited only per-IP.

8. **No metrics endpoint.** Limit hits are visible in logs, not as counters. A
   `/metrics` Prometheus surface is the natural Phase 2 addition.

9. **`AsyncLocalStorage` has a measurable cost** on async-heavy paths (low
   single-digit percent). One store entered once per request is the cheapest
   form of it, but it is not free.

10. **PII masking is heuristic.** `redactText` targets the shapes that actually
    appear in this system. A new log line with a novel secret shape would not be
    caught by pattern matching — only key-based redaction is exhaustive.

11. **`/health` reports a snapshot up to 15s old.** Deliberate (see §1.7);
    `dependenciesCheckedAt` exposes the age so staleness is detectable.

12. **Everything in §2.2** — most importantly the complete absence of
    authentication, and unverified payment callbacks.

**Help24 is not production-hardened after this phase.** It has a production
infrastructure *foundation*: limits that hold under scale, requests that can be
traced, logs that can be searched, dependencies that can be monitored, and a
Redis layer that fails safely. The authentication gap in §2.2 (A) and (B) is
larger than everything this phase fixed, and should be the next phase.

---

## 5. What was verified, and how

**Automated — `npx jest`:** 345 passing, 15 skipped (the opt-in Redis
integration suite), 0 failing. 219 of those pre-existed and still pass
unchanged. `npx tsc --noEmit` clean.

New coverage: redaction (13), request context + middleware (15), local fallback
incl. memory bounds (14), rate-limit service (16), guard (10), policy catalogue
(14), Redis config (14), health service (12), structured logger (16).

**Live — booted the built server on port 3199** against a synthetic environment
with Supabase pointed at an unreachable address (so the background sweeps could
not touch real data):

- `GET /health` → **200** with `status: degraded`, database `unavailable`
  (3018ms timeout), redis `degraded`, firebase `healthy` (642ms — a real token
  minted against Google). Confirms the liveness/dependency split: the endpoint
  stayed 200 with the database down.
- `POST /mpesa/test-stk` ×4 → 200, 200, 200, **429**. Headers on every response:
  `RateLimit-Limit: 3`, `Remaining: 2/1/0`, `RateLimit-Policy: payments:smoke`,
  `RateLimit-Degraded: true`; on the 429, `Retry-After: 3600` and a body
  carrying `retryAfterSeconds`, `policy` and `requestId`.
- Request ID present on **200, 400, 404 and 429** responses and in the body of
  every error. A valid inbound ID was adopted; a hostile one replaced.
- One `requestId` grep returned both the `RateLimitGuard` denial line and the
  `HTTP` access line for that request.
- Access log confirmed as one-line JSON with every required field; the 429 line
  logged at `WARN` with `rateLimited: true`.
- **PII check: `254712345678` appears 0 times** in the log despite untouched
  controller code logging it verbatim.
- The degraded-Redis boot banner fired as designed.

**Two real bugs were found by this verification and fixed:**
Nest could not resolve `StructuredLogger`'s and `RedisService`'s optional
constructor arguments (needed `@Optional()`), and `IdentityMiddleware`'s
dependency was not visible in `AppModule`'s injector (needed a re-export). Both
were boot-time failures that no unit test would have caught.

A third was found by a test: `StructuredLogger.write()` redacted the message
but **not** the structured fields — a live secret-leak path into the access log.
Fixed, plus reserved-key shadowing protection.

A fourth was found while writing tests: rewriting token-bucket state on every
denial accumulated floating-point error, making buckets permanently stricter
than configured. Recomputing from a stable anchor is exact *and* simpler; the
anti-expiry guarantee is preserved by `PEXPIRE` alone. Verified by a test
asserting that 100 attempts over one refill interval yield **exactly** the
configured rate.
