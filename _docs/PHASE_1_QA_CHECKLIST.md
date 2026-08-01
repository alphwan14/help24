# Phase 1 — Production Infrastructure QA Checklist

Exhaustive manual verification. Every item has an **Expected Result**, a
**Pass Criteria** and **Failure Indicators**.

Work top to bottom: §1 gates everything else, because it is the one thing that
could not be verified during implementation.

---

## Setup

```bash
cd backend
npm install
npm run build
```

Two shells are useful throughout: one running the server, one issuing requests.

**Conventions below**

- `$API` — `http://localhost:3000` locally, or your Render URL.
- `-i` on curl to see headers. `| jq` where a body is inspected.
- "the log" — server stdout, or `docker compose logs -f api`.

---

## §1 — Redis + Lua scripts (RUN THIS FIRST)

> The Lua scripts were never executed against a live Redis during
> implementation (WSL Redis was bound to its own loopback; the Docker daemon
> was down). Every claim about atomicity and correctness under concurrency
> rests on this section. **Do not proceed past §1 until it passes.**

### 1.1 Reach Redis from where the tests run

```bash
# Inside WSL:
redis-cli ping                # expect PONG
redis-cli config get bind     # if 127.0.0.1, Windows cannot reach it

# Simplest path — use the compose Redis instead:
cd /path/to/help24 && docker compose up -d redis
docker compose exec redis redis-cli --no-auth-warning -a help24_local_redis ping
```

- **Expected Result:** `PONG` from a Redis reachable at a URL you can use.
- **Pass Criteria:** you have a working `REDIS_TEST_URL`.
- **Failure Indicators:** `Connection refused` — Redis is bound to a loopback
  the test process cannot reach. Use the compose instance, or set
  `bind 0.0.0.0` in WSL (dev only, never on a routable network).

### 1.2 Run the integration suite

```bash
cd backend
REDIS_TEST_URL=redis://:help24_local_redis@127.0.0.1:6379 \
  npx jest redis-scripts.integration --verbose
```

- **Expected Result:** 15 tests pass, none skipped.
- **Pass Criteria:** every test green — in particular the two named
  `IS ATOMIC`, the `refreshes the TTL on a DENIED request` test, and
  `uses the SERVER clock, not the caller clock`.
- **Failure Indicators:**
  - `SKIPPED` in the output → `REDIS_TEST_URL` was not picked up. Nothing was
    verified.
  - `Write commands not allowed after non deterministic commands` → Redis older
    than 5. Upgrade; limits are not reliable on that version.
  - An `IS ATOMIC` test failing → **stop.** The limiter is racy and no limit in
    the system can be trusted.
  - `NOSCRIPT` errors → script caching is broken.

### 1.3 Atomicity under real concurrency (independent of the suite)

```bash
# 100 simultaneous requests, limit is 3/hour per IP.
for i in $(seq 1 100); do curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST $API/mpesa/test-stk -H 'content-type: application/json' \
  -d '{"phone":"254700000000","amount":1}' & done; wait
```

- **Expected Result:** exactly 3 responses of `200`, 97 of `429`.
- **Pass Criteria:** the count of non-429 responses is **exactly** the policy
  limit — not "about" it.
- **Failure Indicators:** 4+ allowed → the check-and-consume is not atomic.
  0 allowed → keys were not reset between runs (wait for the window, or
  `redis-cli --scan --pattern 'help24:*:rl:payments:smoke:*' | xargs redis-cli del`).

### 1.4 Keys look right and expire

```bash
redis-cli --scan --pattern 'help24:*:rl:*' | head -20
redis-cli pttl <one-of-those-keys>
```

- **Expected Result:** keys shaped
  `help24:<env>:rl:<policy>:<rule>:<16-hex>`; `PTTL` returns a positive number.
- **Pass Criteria:** no raw user ID, phone number or IP address appears in any
  key. Every key has a TTL.
- **Failure Indicators:** `PTTL` of `-1` (no expiry — memory will grow without
  bound). A readable identity in a key name. A missing environment segment
  (staging and production would share budget).

### 1.5 Environment isolation

```bash
NODE_ENV=staging   REDIS_URL=... node dist/main.js   # note the key prefix logged
NODE_ENV=production REDIS_URL=... node dist/main.js
```

- **Expected Result:** boot log shows `keyPrefix="help24:staging"` then
  `keyPrefix="help24:production"`.
- **Pass Criteria:** the prefixes differ; consuming budget under one does not
  affect the other.
- **Failure Indicators:** identical prefixes → a staging load test will throttle
  production users.

---

## §2 — Redis failure behaviour

### 2.1 Boot with no Redis configured

```bash
unset REDIS_URL; node dist/main.js
```

- **Expected Result:** the server starts. A boxed `WARN` banner reads
  `RATE LIMITING IS DEGRADED — REDIS_URL is not set`.
- **Pass Criteria:** starts, serves traffic, banner is unmissable.
- **Failure Indicators:** crash on boot (a missing Redis must not stop an
  already-deployed service); **or** no banner (silent degradation is the single
  worst outcome of this phase).

### 2.2 Boot with Redis configured but down

```bash
docker compose stop redis
REDIS_URL=redis://:help24_local_redis@127.0.0.1:6379 node dist/main.js
```

- **Expected Result:** boots after ~5s (`connectTimeoutMs`), logs
  `Not ready within 5000ms … continuing in DEGRADED mode`.
- **Pass Criteria:** boot is not blocked indefinitely; requests still serve.
- **Failure Indicators:** hangs at startup; or connection errors printed on
  every retry (they should be throttled to one per 30s with a suppressed count).

### 2.3 `REDIS_REQUIRED=true` fails the deploy instead

```bash
docker compose stop redis
REDIS_REQUIRED=true REDIS_URL=redis://127.0.0.1:6379 node dist/main.js; echo "exit=$?"
```

- **Expected Result:** process exits non-zero with
  `REDIS_REQUIRED=true and Redis … was not ready`.
- **Pass Criteria:** `exit=1`. On Render/compose this holds the previous version
  in place rather than shipping weaker guarantees.
- **Failure Indicators:** starts anyway → the safety valve does not work.

### 2.4 Redis dies mid-traffic — fail-open to a degraded limiter

```bash
# With Redis up and traffic flowing:
docker compose stop redis
curl -i $API/feed
```

- **Expected Result:** requests keep succeeding. Responses carry
  `RateLimit-Degraded: true`. The log shows one `[RATELIMIT] DEGRADED` warning
  per 30s with an affected-request count.
- **Pass Criteria:** **no 5xx and no added latency.** Latency is the key
  signal — `enableOfflineQueue: false` is what prevents requests stalling.
- **Failure Indicators:** requests hang for seconds → the offline queue is
  enabled and a Redis outage has become an API outage. 500s → the limiter is
  throwing instead of falling back. A log line per request → throttling broken.

### 2.5 Limits still enforce while degraded

```bash
docker compose stop redis
for i in $(seq 1 6); do curl -s -o /dev/null -w "%{http_code} " \
  -X POST $API/mpesa/test-stk -H 'content-type: application/json' \
  -d '{"phone":"254700000000"}'; done; echo
```

- **Expected Result:** `200 200 200 429 429 429`.
- **Pass Criteria:** the fallback enforces the same numbers. **Fail-open means
  degraded, not off.**
- **Failure Indicators:** all 200 → a Redis outage silently removes every limit
  in the system. This is a release blocker.

### 2.6 Automatic reconnect

```bash
docker compose start redis
# wait ~10s
curl -s $API/health/redis | jq '.status, .meta.status'
```

- **Expected Result:** `"healthy"`, `"ready"`. The log shows
  `Reconnected after Ns of degraded operation`.
- **Pass Criteria:** recovery is automatic, with no restart, and
  `RateLimit-Degraded` disappears from responses.
- **Failure Indicators:** stays `unavailable` after Redis returns; or the log
  shows `Client has STOPPED reconnecting` (permanent degradation until restart).

### 2.7 Graceful shutdown closes Redis

```bash
# Ctrl-C, or: docker compose stop api
```

- **Expected Result:** `SIGTERM received — draining HTTP, background sweeps and
  the Redis connection`, then `[REDIS] Connection closed cleanly.`
- **Pass Criteria:** clean close within the 30s grace period.
- **Failure Indicators:** `Clean close timed out — socket force-closed` on every
  shutdown; or the process hanging until SIGKILL.

---

## §3 — Rate limit verification

Reference: `backend/src/common/rate-limit/rate-limit.policies.ts` — every number
with its reasoning. Reset state between tests:

```bash
redis-cli --scan --pattern 'help24:*:rl:*' | xargs -r redis-cli del
```

### 3.1 Headers on ALLOWED responses

```bash
curl -i $API/feed | grep -i 'ratelimit'
```

- **Expected Result:** `RateLimit-Limit`, `RateLimit-Remaining`,
  `RateLimit-Reset`, `RateLimit-Policy: feed:read`, plus `X-RateLimit-*`.
- **Pass Criteria:** `Remaining` decrements on each call. Headers appear on
  **successful** responses — that is what lets a client self-throttle.
- **Failure Indicators:** no headers; `Remaining` static; wrong policy name.

### 3.2 The 429 contract

Exhaust any limit, then:

```bash
curl -i -X POST $API/mpesa/test-stk -H 'content-type: application/json' -d '{"phone":"254700000000"}'
```

- **Expected Result:** `429`, `Retry-After: <seconds>`, body:
  `{"statusCode":429,"message":"Too many requests…","path":…,"timestamp":…,
    "requestId":…,"retryAfterSeconds":…,"policy":"payments:smoke"}`
- **Pass Criteria:** `Retry-After ≥ 1` (never 0), `requestId` present, `policy`
  names the right policy.
- **Failure Indicators:** 500 instead of 429; `Retry-After: 0` (invites an
  immediate retry); missing `requestId` (a user cannot report it).

### 3.3 Per-endpoint limits

Run each; confirm the Nth+1 request is 429.

| Endpoint | Policy | Limit to expect |
|---|---|---|
| `POST /providers/verify-payout` | `otp:verify` | 6th in 15 min (same `provider_id`) → 429 |
| `POST /providers/register` | `otp:issue` | 4th in an hour → 429 |
| `POST /mpesa/initiate` | `payments:initiate` | 6th in 10 min (same `buyer_user_id`) → 429 |
| `POST /mpesa/test-stk` | `payments:smoke` | 4th in an hour → 429 |
| `POST /mpesa/release-payout` | `payments:release` | 6th in an hour (same `post_id`) → 429 |
| `GET /admin/invite/xyz` | `admin:auth` | 11th in a minute → 429 |
| `POST /disputes/create` | `disputes:create` | 6th in an hour → 429 |
| `POST /notifications/chat-message` | `messaging:notify` | 41st burst → 429 |
| `POST /routes/compute` | `routes:compute` | 41st cache-MISS in 10 min → `{"available":false,"reason":"rate_limited"}` |

- **Pass Criteria:** each trips at its documented number, and **not before**.
- **Failure Indicators:** tripping early (a shipped client will break); never
  tripping (the decorator is missing — check with
  `grep -rn "@RateLimit" src/<module>`).

> **`/routes/compute` is different by design.** It answers HTTP 200 with
> `{"available":false,"reason":"rate_limited"}` rather than 429, because the
> app treats any non-200 as a failure. Its limit is applied inside the service
> after the cache lookup, so **repeating the same coordinates does not consume
> budget** — vary them to test.

### 3.4 Subject isolation

```bash
# Exhaust user A, then try user B from the same machine.
for i in $(seq 1 6); do curl -s -o /dev/null -X POST $API/mpesa/initiate \
  -H 'content-type: application/json' -d '{"post_id":"p1","buyer_user_id":"userA"}'; done
curl -i -X POST $API/mpesa/initiate -H 'content-type: application/json' \
  -d '{"post_id":"p1","buyer_user_id":"userB"}' | head -1
```

- **Expected Result:** user B is allowed (its own subject bucket) until the
  shared **IP** rule (60/10min) is reached.
- **Pass Criteria:** subject buckets are independent; the IP rule still caps the
  total.
- **Failure Indicators:** B blocked immediately → keys are not subject-scoped.
  B never blocked even past 60 → the IP rule is missing, and rotating `user_id`
  fully evades the limit.

### 3.5 Cross-instance enforcement — the point of the whole phase

```bash
PORT=3001 node dist/main.js &
PORT=3002 node dist/main.js &
# Same REDIS_URL for both. Alternate requests:
for i in $(seq 1 3); do
  curl -s -o /dev/null -w "3001:%{http_code} " -X POST localhost:3001/mpesa/test-stk \
    -H 'content-type: application/json' -d '{"phone":"254700000000"}'
  curl -s -o /dev/null -w "3002:%{http_code} " -X POST localhost:3002/mpesa/test-stk \
    -H 'content-type: application/json' -d '{"phone":"254700000000"}'
done; echo
```

- **Expected Result:** exactly **3** `200`s across BOTH instances combined, then
  429 from either.
- **Pass Criteria:** the budget is shared. This is the single most important
  test in the document — it is the difference between this phase working and
  not.
- **Failure Indicators:** 3 allowed on each instance (6 total) → state is not
  shared; check both processes have the same `REDIS_URL` **and** the same
  `REDIS_KEY_PREFIX`/`NODE_ENV`.

### 3.6 Sliding window genuinely slides

```bash
# 3 requests, wait past the window, confirm budget returns gradually not all at once.
for i in 1 2 3; do curl -s -o /dev/null -X POST $API/mpesa/test-stk \
  -H 'content-type: application/json' -d '{"phone":"254700000000"}'; sleep 2; done
curl -i -X POST $API/mpesa/test-stk -H 'content-type: application/json' \
  -d '{"phone":"254700000000"}' | grep -i 'retry-after'
```

- **Expected Result:** `Retry-After` reflects when the OLDEST entry ages out —
  slightly less than the full window.
- **Pass Criteria:** `Retry-After` decreases as the oldest entries age.
- **Failure Indicators:** `Retry-After` always equal to the full window → a
  fixed window, which permits double the limit across its boundary.

### 3.7 Token bucket absorbs a burst

```bash
for i in $(seq 1 60); do curl -s -o /dev/null -w "%{http_code} " $API/feed; done; echo
```

- **Expected Result:** all 200 (capacity is 90), then sustained requests limited
  to ~60/min.
- **Pass Criteria:** the burst succeeds — a cold app start firing several
  requests must never be rejected.
- **Failure Indicators:** 429 inside the first 90 → capacity is not being
  applied and real users will hit it.

### 3.8 `/health` is exempt

```bash
for i in $(seq 1 200); do curl -s -o /dev/null -w "%{http_code} " $API/health; done | tr ' ' '\n' | sort | uniq -c
```

- **Expected Result:** 200 × 200. No `RateLimit-*` headers on `/health`.
- **Pass Criteria:** never 429. A 429 here makes every device behind a carrier
  NAT display "you are offline".
- **Failure Indicators:** any 429; or `RateLimit-*` headers present.

### 3.9 The default policy covers undecorated routes

Add a temporary endpoint with no `@RateLimit`, hit it 1000×.

- **Expected Result:** 429 after ~900 (default IP bucket).
- **Pass Criteria:** an undecorated route is still protected.
- **Failure Indicators:** never limited → the global `APP_GUARD` is not
  registered.

### 3.10 Catalogue integrity

```bash
npx jest rate-limit.policies
```

- **Expected Result:** 14 tests pass.
- **Pass Criteria:** every policy has a rationale; subject rules precede IP
  rules; every IP rule is at least as permissive as its subject rule; money
  endpoints use the exact algorithm.
- **Failure Indicators:** any failure — a policy is misconfigured in a way that
  would not otherwise surface until it misbehaved in production.

---

## §4 — Abuse testing

### 4.1 OTP brute force (the headline fix)

```bash
for i in $(seq 1 50); do curl -s -o /dev/null -w "%{http_code} " \
  -X POST $API/providers/verify-payout -H 'content-type: application/json' \
  -d "{\"provider_id\":\"<real-uuid>\",\"otp_code\":\"$(printf '%06d' $i)\"}"; done; echo
```

- **Expected Result:** at most 5 reach the handler; the rest 429. Rotating
  `provider_id` still caps at 30/hour from one IP.
- **Pass Criteria:** fewer than ~30 guesses/hour reach the OTP check.
- **Failure Indicators:** all 50 processed → **release blocker**; a 6-digit code
  is brute-forceable inside its 5-minute validity.

### 4.2 Subject rotation does not evade the IP rule

```bash
for i in $(seq 1 100); do curl -s -o /dev/null -w "%{http_code} " \
  -X POST $API/mpesa/initiate -H 'content-type: application/json' \
  -d "{\"post_id\":\"p$i\",\"buyer_user_id\":\"user$i\"}"; done | tr ' ' '\n' | sort | uniq -c
```

- **Expected Result:** ~60 processed, the rest 429 (IP rule).
- **Pass Criteria:** rotation is capped by the IP rule.
- **Failure Indicators:** all 100 processed → the IP rule is missing and every
  per-subject limit is bypassable by changing one body field.

### 4.3 STK push harassment

```bash
for i in $(seq 1 20); do curl -s -o /dev/null -w "%{http_code} " \
  -X POST $API/mpesa/test-stk -H 'content-type: application/json' \
  -d '{"phone":"254712345678"}'; done; echo
```

- **Expected Result:** 3 × 200, 17 × 429.
- **Pass Criteria:** a victim receives at most 3 unsolicited prompts per hour
  per attacking IP.
- **Failure Indicators:** more than 3 → unbounded phone harassment.
- **Note:** this endpoint should not exist in production at all — see the
  security report §2.2(D).

### 4.4 Upload-URL farming

```bash
for i in $(seq 1 15); do curl -s -o /dev/null -w "%{http_code} " \
  -X POST $API/disputes/<id>/evidence/upload-url -H 'content-type: application/json' \
  -d '{"user_id":"u1","files":[{"name":"a.jpg","type":"image/jpeg"}]}'; done; echo
```

- **Expected Result:** ~10 succeed (20/hour at cost 2), rest 429.
- **Pass Criteria:** signed write capabilities are capped.
- **Failure Indicators:** unlimited → unbounded storage growth from one caller.

### 4.5 Callback flood does not exhaust the database

```bash
for i in $(seq 1 500); do curl -s -o /dev/null -X POST $API/mpesa/stk-callback \
  -H 'content-type: application/json' -d '{"Body":{"stkCallback":{"ResultCode":0}}}' & done; wait
curl -s $API/health/database | jq .status
```

- **Expected Result:** service stays responsive; database reports `healthy`.
- **Pass Criteria:** `/health` and other endpoints keep answering throughout.
- **Failure Indicators:** the API becomes unresponsive → the callback limit is
  too loose for your database's connection pool.
- **⚠️ Known gap:** this limit is deliberately the loosest in the catalogue
  (dropping a genuine Daraja callback means a payment that never settles). It
  does **not** protect against *forged* callbacks — see security report §2.2(B).

### 4.6 Log injection

```bash
curl -i $API/health/redis -H 'X-Request-Id: evil
FAKE_LOG_ENTRY level=ERROR'
```

- **Expected Result:** a fresh UUID in `X-Request-Id`; no forged line in the log.
- **Pass Criteria:** the hostile value never reaches the log or the header.
- **Failure Indicators:** the injected string echoed back → header-injection
  vector.

### 4.7 Memory bound of the fallback

```bash
docker compose stop redis
for i in $(seq 1 20000); do curl -s -o /dev/null -X POST $API/mpesa/initiate \
  -H 'content-type: application/json' -d "{\"post_id\":\"p\",\"buyer_user_id\":\"u$i\"}"; done
# Watch RSS:
ps -o rss= -p $(pgrep -f 'node dist/main.js')
```

- **Expected Result:** memory plateaus; no OOM.
- **Pass Criteria:** RSS stabilises (cap is 50k keys).
- **Failure Indicators:** unbounded growth → a Redis outage becomes an OOM crash.

---

## §5 — Authentication testing

> Read security report §2.2(A) first. **This backend does not authenticate any
> user-facing endpoint today.** These tests establish that as a known baseline
> so the next phase can prove it changed — several of them are *expected to
> "fail"* in the sense that the request succeeds when it should not.

### 5.1 Baseline: unauthenticated access succeeds (known gap)

```bash
curl -i -X POST $API/mpesa/initiate -H 'content-type: application/json' \
  -d '{"post_id":"<real>","buyer_user_id":"<someone-elses-id>"}'
```

- **Expected Result (today):** the request is processed.
- **Pass Criteria for THIS phase:** it is rate limited (`RateLimit-*` headers
  present) and logged with `userIdSource: asserted`.
- **Failure Indicators:** no rate-limit headers → the endpoint is unprotected on
  every axis.
- **Record this.** After the auth phase it must return 401.

### 5.2 A Firebase token is verified when present

```bash
TOKEN=$(<a real Firebase ID token>)
curl -s $API/feed -H "Authorization: Bearer $TOKEN" -o /dev/null
grep '"userIdSource":"verified"' <the log> | tail -1
```

- **Expected Result:** the access log shows `userIdSource: "verified"` and
  `userId` equal to the Firebase UID.
- **Pass Criteria:** a valid token is resolved and recorded.
- **Failure Indicators:** always `asserted` → Firebase Admin is not initialized
  (check `/health/firebase`) or the middleware is not running.

### 5.3 An invalid token does not break the request

```bash
curl -i $API/feed -H 'Authorization: Bearer totally.invalid.token'
```

- **Expected Result:** 200. No `userId` recorded, or an `asserted` one.
- **Pass Criteria:** identity resolution is **non-enforcing** — it never rejects.
- **Failure Indicators:** 401/500 → enforcement was switched on prematurely and
  every shipped client will break.

### 5.4 Admin auth still works and is rate limited

```bash
curl -i $API/admin/me -H "Authorization: Bearer $ADMIN_TOKEN"
for i in $(seq 1 15); do curl -s -o /dev/null -w "%{http_code} " \
  $API/admin/invite/fake-token-$i; done; echo
```

- **Expected Result:** valid admin token → 200. Invite lookups → 10 processed
  then 429.
- **Pass Criteria:** admin routes are unchanged in behaviour; the public admin
  surface is rate limited.
- **Failure Indicators:** admin routes now 429 during normal dashboard use →
  `admin:api` (240 burst / 120 per min per IP) is too tight for your team size.

### 5.5 Rate limiting runs BEFORE admin auth

```bash
for i in $(seq 1 300); do curl -s -o /dev/null -w "%{http_code} " \
  $API/admin/disputes -H "Authorization: Bearer invalid-$i"; done | tr ' ' '\n' | sort | uniq -c
```

- **Expected Result:** a mix of 401 and 429; 429 appears once the IP bucket
  drains.
- **Pass Criteria:** invalid tokens stop reaching the database once the limit is
  hit.
- **Failure Indicators:** 401 for all 300 → every brute-force attempt is a
  database query.

---

## §6 — Payment endpoint testing

**Use the M-Pesa sandbox. Do not run these against production credentials.**

### 6.1 A real payment still works end to end

- **Expected Result:** `POST /mpesa/initiate` → prompt on the phone → callback →
  transaction `paid`.
- **Pass Criteria:** **unchanged behaviour.** Phase 1 must not alter the payment
  flow at all.
- **Failure Indicators:** any change in response shape or timing; a 429 during a
  single normal payment (limit is 5/10min per payer — one payment plus retries
  must never trip it).

### 6.2 Payment status polling is not throttled

Start a payment and let the app poll for the full STK timeout (~2 min at 5s
intervals ≈ 24 polls).

- **Expected Result:** every poll returns 200.
- **Pass Criteria:** no 429 during a normal payment. `payments:read` is 40 burst
  / 30 per min, sized against `payment_screen.dart`'s measured 5s interval.
- **Failure Indicators:** any 429 → the payment screen will appear to hang; the
  limit is mis-sized.

### 6.3 Genuine callbacks are never dropped

```bash
for i in $(seq 1 200); do curl -s -o /dev/null -w "%{http_code} " \
  -X POST $API/mpesa/stk-callback -H 'content-type: application/json' \
  -d '{"Body":{"stkCallback":{"ResultCode":0,"CheckoutRequestID":"x"}}}'; done | tr ' ' '\n' | sort | uniq -c
```

- **Expected Result:** all 200.
- **Pass Criteria:** zero 429 at 200 callbacks/minute from one IP.
- **Failure Indicators:** **any 429 is a serious problem** — Safaricom delivers
  from a small set of shared addresses, and a rejected callback is a payment
  that never settles.

### 6.4 Payout release is capped per post

```bash
for i in $(seq 1 8); do curl -s -o /dev/null -w "%{http_code} " \
  -X POST $API/mpesa/release-payout -H 'content-type: application/json' \
  -d '{"post_id":"<same-post>"}'; done; echo
```

- **Expected Result:** at most 5 reach the handler; a genuine second attempt
  still returns 409 `Payout already released.`
- **Pass Criteria:** the rate limit is defence in depth **over** the existing
  transaction-state guard, not a replacement for it.
- **Failure Indicators:** two payouts actually dispatched for one post → a
  correctness bug in the settlement path, unrelated to rate limiting, and far
  more serious.

### 6.5 No payment secret reaches the log

```bash
grep -iE 'passkey|consumer_secret|SecurityCredential|"password"' <the log> | head
grep -E '254[0-9]{9}' <the log> | head
```

- **Expected Result:** no output from either.
- **Pass Criteria:** M-Pesa credentials and full customer phone numbers are
  absent. Phones appear masked (`254******678`).
- **Failure Indicators:** any match → a credential or PII leak into logs.

---

## §7 — Health endpoint verification

### 7.1 `/health` shape and backwards compatibility

```bash
curl -s $API/health | jq
```

- **Expected Result:** `status`, `service: "help24-backend"`, `timestamp`, plus
  `uptimeSeconds`, `requestId`, `dependencies`, `dependenciesCheckedAt`.
- **Pass Criteria:** the three original fields are unchanged, and `status` is
  exactly `"ok"` when all dependencies are healthy.
- **Failure Indicators:** a missing original field → the Docker HEALTHCHECK or
  the app's connectivity probe may break.

### 7.2 `/health` stays 200 when a dependency is down

```bash
docker compose stop redis
curl -s -o /dev/null -w "%{http_code}\n" $API/health
curl -s $API/health | jq '.status, .dependencies.redis.status'
```

- **Expected Result:** `200`; `"degraded"`, `"degraded"`.
- **Pass Criteria:** **never 503.** A 503 restarts healthy containers and makes
  every device show "you are offline".
- **Failure Indicators:** 503 → the liveness/dependency split is broken.

### 7.3 `/health` is O(1) and independent of dependency latency

```bash
# Break the database (point SUPABASE_URL at an unreachable host) and restart.
time curl -s -o /dev/null $API/health
```

- **Expected Result:** responds in **milliseconds** even with the database
  timing out.
- **Pass Criteria:** under 100ms, far inside the app's 5s probe timeout.
- **Failure Indicators:** seconds → it is probing inline; a slow Supabase would
  make every device declare itself offline.

### 7.4 `/health/database` performs a real query

```bash
curl -s $API/health/database | jq
```

- **Expected Result:** `status: "healthy"`, a real `latencyMs`,
  `meta.table: "posts"`.
- **Pass Criteria:** `latencyMs` varies between calls — proof of a real query.
- **Failure Indicators:** `latencyMs: 0` or constant → not actually querying.
  Point `SUPABASE_URL` at an unreachable host and confirm it flips to
  `unavailable` with HTTP 503.

### 7.5 `/health/redis` reflects reality

```bash
curl -s $API/health/redis | jq            # → healthy
docker compose stop redis
curl -s -o /dev/null -w "%{http_code}\n" $API/health/redis   # → 503
unset REDIS_URL   # restart without it
curl -s $API/health/redis | jq .status    # → degraded, HTTP 200
```

- **Pass Criteria:** three distinct states — `healthy`, `unavailable` (503),
  `degraded` (200, unconfigured).
- **Failure Indicators:** unconfigured reported as `healthy` (hides a production
  misconfiguration) or as `unavailable` (pages someone for an intended dev
  state).

### 7.6 `/health/firebase` verifies the credential, not just the object

```bash
curl -s $API/health/firebase | jq
# Then corrupt FIREBASE_PRIVATE_KEY and restart.
```

- **Expected Result:** healthy with a real `latencyMs` and `meta.projectId`;
  with a corrupted key, `degraded` and a detail containing the Google error.
- **Pass Criteria:** a bad credential is caught **here**, not on the first push.
- **Failure Indicators:** still `healthy` with a broken key → the probe only
  checks that an object exists.

### 7.7 `/health/events` is unchanged

```bash
curl -s $API/health/events | jq
```

- **Expected Result:** the original processor status shape.
- **Pass Criteria:** unchanged; the new `/health/*` routes did not shadow it.
- **Failure Indicators:** 404 → a route collision.

### 7.8 Deep probes coalesce

```bash
for i in $(seq 1 50); do curl -s -o /dev/null $API/health/database & done; wait
```

- **Expected Result:** far fewer than 50 queries reach Supabase.
- **Pass Criteria:** single-flight prevents the health endpoint amplifying load.
- **Failure Indicators:** 50 queries → the endpoint is a load generator against
  the thing it monitors.

---

## §8 — Request ID tracing

### 8.1 Every response carries one

```bash
for p in /health /health/redis /feed /does-not-exist; do
  echo -n "$p → "; curl -s -i "$API$p" | grep -i '^x-request-id'; done
```

- **Expected Result:** a header on all four, including the 404.
- **Pass Criteria:** present on 2xx, 4xx and 5xx alike.
- **Failure Indicators:** missing on 404/429 → the ID comes from an interceptor
  rather than middleware, and the responses that most need tracing lack it.

### 8.2 One ID reconstructs the whole request

```bash
RID=$(curl -s -i -X POST $API/mpesa/test-stk -H 'content-type: application/json' \
  -d '{"phone":"254700000000"}' | grep -i '^x-request-id' | tr -d '\r' | awk '{print $2}')
grep "$RID" <the log>
```

- **Expected Result:** every line for that request — service logs, the rate-limit
  verdict, the access line.
- **Pass Criteria:** **this is the acceptance test for Part 2.** One ID, complete
  reconstruction.
- **Failure Indicators:** only the access line appears → `AsyncLocalStorage` is
  not propagating into services.

### 8.3 An inbound ID is adopted

```bash
curl -s -i $API/health/redis -H 'X-Request-Id: device-trace-0001' | grep -i '^x-request-id'
grep 'device-trace-0001' <the log>
```

- **Expected Result:** echoed verbatim; the log line shows
  `requestIdInherited: true`.
- **Pass Criteria:** a device-originated trace stays one trace end to end.
- **Failure Indicators:** replaced with a UUID → check the ID is 8–128 chars of
  `[A-Za-z0-9._:-]`.

### 8.4 The ID survives an exception

Force a 500 (e.g. break `SUPABASE_URL` and call an endpoint that queries):

- **Expected Result:** the 500 response body contains `requestId`, and the log
  has the stack trace under the same ID.
- **Pass Criteria:** correlation survives the exception filter.
- **Failure Indicators:** no `requestId` in the error body — the user has
  nothing to quote to support.

### 8.5 Concurrent requests do not cross ids

```bash
for i in $(seq 1 30); do curl -s -i $API/health/redis & done; wait
```

- **Expected Result:** 30 distinct IDs.
- **Pass Criteria:** no duplicates.
- **Failure Indicators:** repeated IDs → context leaking between requests, which
  would attribute log lines to the wrong user.

---

## §9 — Logging verification

### 9.1 Format switching

```bash
LOG_FORMAT=json node dist/main.js    # one JSON object per line
LOG_FORMAT=pretty node dist/main.js  # aligned, coloured
```

- **Pass Criteria:** every JSON line parses (`… | jq -c . > /dev/null` with no
  errors). Default is `json` when `NODE_ENV=production`, `pretty` otherwise.
- **Failure Indicators:** mixed formats in one stream → something is still using
  `console.log`.

### 9.2 The access log has every required field

```bash
grep '"context":"HTTP"' <the log> | tail -1 | jq
```

- **Expected Result:** `timestamp, requestId, method, endpoint, route, status,
  latencyMs, ip, userAgent` (plus `userId`, `userIdSource`, `rateLimitPolicy`
  when applicable).
- **Pass Criteria:** all Part-3 fields present; `latencyMs` is a plausible
  number; `ip` is the **client** IP, not the proxy's.
- **Failure Indicators:** `ip` identical for all users behind a proxy →
  `trust proxy` is not taking effect, and every IP rule throttles the whole user
  base collectively.

### 9.3 Failures are logged at the right severity

```bash
grep '"status":429' <the log> | jq -r .level   # → WARN
grep '"status":404' <the log> | jq -r .level   # → WARN
grep '"status":500' <the log> | jq -r .level   # → ERROR
```

- **Pass Criteria:** 5xx → ERROR, 4xx → WARN, 2xx → INFO.
- **Failure Indicators:** everything INFO → alerting on error rate is impossible.

### 9.4 Successful `/health` probes are quiet

```bash
for i in $(seq 1 50); do curl -s -o /dev/null $API/health; done
grep -c '"endpoint":"/health"' <the log>
```

- **Expected Result:** `0` at the default log level.
- **Pass Criteria:** successful liveness probes do not flood the log. With
  `LOG_LEVEL=debug` they appear.
- **Failure Indicators:** 50 lines → at real user counts the log is ~90% health
  checks, burying the signal and costing money on a hosted platform.

### 9.5 No secrets, anywhere

```bash
grep -iE 'bearer [a-z0-9]{8}|eyJ[A-Za-z0-9_-]{10}|"password"|passkey|consumer_secret|service_role' <the log>
grep -E '(^|[^0-9])254[0-9]{9}([^0-9]|$)' <the log>
```

- **Expected Result:** no output from either.
- **Pass Criteria:** **zero** matches. Tokens show as `[REDACTED]` /
  `[REDACTED_JWT]`, phones as `254******678`.
- **Failure Indicators:** any match → a credential or PII leak. Check whether a
  new log line introduced an unrecognised secret shape.

### 9.6 Existing service logs gained correlation for free

```bash
grep '"context":"MpesaService"' <the log> | tail -1 | jq '.requestId, .context'
```

- **Expected Result:** a `requestId` on a log line from an untouched service.
- **Pass Criteria:** confirms the zero-call-site-change migration worked.
- **Failure Indicators:** no `requestId` → `app.useLogger()` did not install the
  structured logger.

### 9.7 Stack traces are present

Force an unhandled error.

- **Expected Result:** a `stack` field with the full trace, under the request's
  ID.
- **Pass Criteria:** trace is complete and correlated.
- **Failure Indicators:** message only → debugging a production 500 is guesswork.

---

## §10 — Docker verification

### 10.1 Config validity

```bash
docker compose config --quiet && echo "VALID"
```

- **Pass Criteria:** `VALID`, no output before it.

### 10.2 Redis starts by default

```bash
docker compose up -d --build
docker compose ps
```

- **Expected Result:** `help24-api` and `help24-redis` both `Up (healthy)`.
- **Pass Criteria:** Redis starts with **no `--profile` flag** — the default
  local stack now matches production.
- **Failure Indicators:** Redis absent → a stale `profiles:` key on the service.

### 10.3 The API reaches Redis in-network

```bash
docker compose logs api | grep -i 'INFRA\|REDIS'
curl -s localhost:3000/health/redis | jq '.status, .meta.url'
```

- **Expected Result:** `Redis ready — redis://:***@redis:6379`, status `healthy`.
- **Pass Criteria:** the URL is the **service name**, and the password is masked.
- **Failure Indicators:** a visible password in the log → a redaction failure.
  `localhost` in the URL → `environment:` is not overriding `env_file`.

### 10.4 Network isolation holds

```bash
docker compose exec redis sh -c 'nc -zv postgres 5432' ; echo "exit=$?"
```

- **Expected Result:** fails — Redis and Postgres share no network.
- **Pass Criteria:** non-zero exit.
- **Failure Indicators:** connects → segmentation is broken and a compromised
  Redis can reach the database.

### 10.5 Redis is not exposed publicly

```bash
docker compose port redis 6379
```

- **Expected Result:** `127.0.0.1:6379`.
- **Pass Criteria:** loopback only.
- **Failure Indicators:** `0.0.0.0:6379` → Redis is reachable from the network
  you happen to be joined to.

### 10.6 Rate-limit state survives an API restart

```bash
for i in $(seq 1 3); do curl -s -o /dev/null -X POST localhost:3000/mpesa/test-stk \
  -H 'content-type: application/json' -d '{"phone":"254700000000"}'; done
docker compose restart api && sleep 10
curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:3000/mpesa/test-stk \
  -H 'content-type: application/json' -d '{"phone":"254700000000"}'
```

- **Expected Result:** `429` — the budget survived the restart.
- **Pass Criteria:** state is in Redis, not in the process.
- **Failure Indicators:** `200` → state is per-process; check the API is
  actually using Redis and not the fallback.

### 10.7 Read-only filesystem still holds

```bash
docker compose exec api sh -c 'touch /app/test' ; echo "exit=$?"
```

- **Expected Result:** fails (read-only filesystem).
- **Pass Criteria:** non-zero exit — nothing added in this phase writes to disk.

### 10.8 Container health check

```bash
docker inspect --format='{{.State.Health.Status}}' help24-api
```

- **Expected Result:** `healthy`.
- **Pass Criteria:** stays healthy even with Redis stopped (`/health` is
  liveness).
- **Failure Indicators:** becomes `unhealthy` when Redis stops → `/health` is
  returning 503 for a dependency and containers will restart pointlessly.

### 10.9 Graceful shutdown

```bash
docker compose stop api    # then:
docker compose logs api | tail -20
```

- **Expected Result:** SIGTERM line, sweeps drained, `[REDIS] Connection closed
  cleanly.`
- **Pass Criteria:** clean stop inside the 30s grace period.
- **Failure Indicators:** stop takes the full 30s → something is not draining.

---

## §11 — Multiple device testing

Real devices on a real network — this is where CGNAT assumptions get tested.

### 11.1 Several devices on one Wi-Fi

Use 3+ devices on the same network simultaneously: browse Discover, open
profiles, send chat messages.

- **Expected Result:** no device sees a 429 or an error toast.
- **Pass Criteria:** normal multi-user activity behind one public IP never trips
  an IP rule.
- **Failure Indicators:** any 429 → an IP rule is sized for a person rather than
  a crowd. **This is the most likely false-positive in the whole phase.**

### 11.2 Mobile data (carrier-grade NAT)

Same test on Safaricom/Airtel mobile data, ideally from several devices.

- **Expected Result:** no rate limiting.
- **Pass Criteria:** works on a connection where hundreds of subscribers may
  share one public IPv4 address.
- **Failure Indicators:** 429s on mobile data but not Wi-Fi → IP limits must be
  raised; check the `ip` field in the access log to see how many distinct users
  share the address.

### 11.3 Connectivity probe unaffected

Leave the app open for 10 minutes on several devices.

- **Expected Result:** no "you are offline" banner.
- **Pass Criteria:** `/health` is never rate limited and never slow.
- **Failure Indicators:** spurious offline banners → check §3.8 and §7.3.

### 11.4 One device, heavy use

Rapidly refresh Discover, change filters, open many profiles for 2 minutes.

- **Expected Result:** no 429.
- **Pass Criteria:** `feed:read` (90 burst / 60 per min) survives an energetic
  user.
- **Failure Indicators:** 429 during ordinary scrolling → the limit is
  mis-sized; capture the `RateLimit-Remaining` trend.

### 11.5 Cold start burst

Force-close and reopen the app 10 times in a minute.

- **Expected Result:** every start loads normally.
- **Pass Criteria:** the token bucket's capacity absorbs the multi-request cold
  start.
- **Failure Indicators:** a later start shows an empty feed or an error →
  capacity is too low.

### 11.6 A complete payment on a real device

- **Expected Result:** identical to before Phase 1.
- **Pass Criteria:** prompt arrives, polling never 429s, callback settles, the
  job funds.
- **Failure Indicators:** any change → a payment-path regression.

---

## §12 — Load behaviour

### 12.1 Baseline latency cost of the limiter

```bash
npx autocannon -c 10 -d 30 $API/health          # exempt from limiting
npx autocannon -c 10 -d 30 $API/health/redis    # limited
```

- **Expected Result:** the limited endpoint adds a small, bounded amount of
  latency (one Redis round trip per rule).
- **Pass Criteria:** added p99 latency is single-digit milliseconds against a
  same-region Redis.
- **Failure Indicators:** tens of milliseconds → Redis is far away or saturated;
  check `/health/redis` latency and the `RedisService` command timeout.

### 12.2 Sustained load

```bash
npx autocannon -c 50 -d 120 $API/feed
```

- **Expected Result:** stable latency; 429s once the bucket drains; **no 5xx**.
- **Pass Criteria:** rejection is orderly. Memory stable throughout.
- **Failure Indicators:** 5xx under load → the limiter is throwing. Latency
  climbing → Redis is the bottleneck.

### 12.3 Redis dies under load

Start a 60s load test; stop Redis at t=20s; restart at t=40s.

- **Expected Result:** no error spike. A brief `RateLimit-Degraded: true` window,
  then automatic recovery.
- **Pass Criteria:** **latency does not spike.** This is the acceptance test for
  `enableOfflineQueue: false`.
- **Failure Indicators:** requests hanging or timing out at t=20s → the offline
  queue is enabled and a Redis outage has become an API outage. **Release
  blocker.**

### 12.4 Redis memory under adversarial key growth

```bash
redis-cli info memory | grep used_memory_human
# Run §4.2 (100 rotated subjects), then re-check.
redis-cli dbsize
```

- **Expected Result:** memory grows modestly and keys expire on their TTL.
- **Pass Criteria:** `dbsize` falls back after the longest window (1 hour).
- **Failure Indicators:** monotonic growth → keys are missing TTLs (§1.4).

### 12.5 Log volume at load

```bash
docker compose logs api --since 1m | wc -l
```

- **Expected Result:** roughly one line per request, plus warnings.
- **Pass Criteria:** health probes are not in the count (§9.4).
- **Failure Indicators:** several lines per request → duplicate logging;
  estimate the monthly cost on your log platform before shipping.

### 12.6 Two instances under load

Run two instances against one Redis; drive load at both.

- **Expected Result:** the combined accepted rate matches the **single**
  configured limit, not double.
- **Pass Criteria:** the headline scalability claim, under load rather than in a
  hand test.
- **Failure Indicators:** roughly double the limit accepted → state is not
  shared (§3.5).

---

## §13 — Regression sweep

Everything below must behave **exactly as it did before Phase 1**.

| # | Check | Pass Criteria |
|---|---|---|
| 13.1 | `npx jest` | 345 pass, 15 skipped (or 360 pass with `REDIS_TEST_URL`), 0 fail |
| 13.2 | `npx tsc --noEmit` | no output |
| 13.3 | `npm run build` | succeeds |
| 13.4 | Boot log route verification | all four `✓ … loaded` lines present |
| 13.5 | `GET /` | original `{status, service, timestamp}` |
| 13.6 | Full job lifecycle | post → apply → select → pay → complete → approve → payout, unchanged |
| 13.7 | Dispute flow | create → reply → evidence → resolve, unchanged |
| 13.8 | Promotion purchase | campaign → pay → serve → analytics, unchanged |
| 13.9 | Admin dashboard | login, dispute queue, campaign moderation all work |
| 13.10 | Discover feed | ranking identical — **nothing in this phase touched it** |
| 13.11 | Chat notifications | push still delivered |
| 13.12 | Journey ETA | `/routes/compute` still returns ETAs; caching still works |
| 13.13 | Background sweeps | event retry, promotions lifecycle, dispute SLA still tick |
| 13.14 | Error response shape | `{statusCode, message, path, timestamp}` — plus `requestId`, nothing removed |

---

## Sign-off

Phase 1 is verified when:

- [ ] **§1 passes in full** — the Lua scripts have been run against a live Redis
- [ ] **§3.5 passes** — limits hold across two instances
- [ ] **§2.5 passes** — limits still enforce while Redis is down
- [ ] **§12.3 passes** — no latency spike when Redis dies under load
- [ ] **§9.5 passes** — zero secrets or PII in logs
- [ ] **§8.2 passes** — one request ID reconstructs a whole request
- [ ] **§7.2 passes** — `/health` stays 200 with a dependency down
- [ ] **§11.1 and §11.2 pass** — real devices on shared IPs are never throttled
- [ ] **§13 passes in full** — no regressions

Then set `REDIS_REQUIRED=true` in production, so a future misconfiguration fails
the deploy instead of silently degrading.

**Before calling Help24 production-ready, read security report §2.2.** The
absence of authentication on user-facing endpoints, and the unverified M-Pesa
callbacks, are larger than anything this phase fixed.
