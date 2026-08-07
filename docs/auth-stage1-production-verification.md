# Authentication Stage 1 — Production Verification Report

Status: **applied and verified.** The unauthenticated promotions exposure is
closed. Every check passed, on production evidence rather than inference.

Target service: **help24-backend** (`srv-d7mjm2v7f7vs73f8qaqg`), Frankfurt, free
plan, 1 instance. The other three services in the workspace (`rentflow`,
`waniala-backend`, `waniala-backend-1`) were read once during discovery and
never touched.

---

## 1. What was actually wrong with the configuration

`AUTH_ENFORCEMENT` **was not set at all.** The service had 19 environment
variables and not one `AUTH_*` among them. Production had been running on the
compiled default, which `auth.config.ts` deliberately sets to `monitor` — the
only value that is both non-breaking and self-reporting. That is why every
`@Auth` route answered 200 without a token.

Also settled while inspecting: **`ADMIN_AUTH_DEBUG` is absent** in production.
That was one of two items flagged as unverifiable in the earlier audit.

## 2. The change, and why it had to be atomic

```
AUTH_ENFORCEMENT  = enforce
AUTH_ENFORCE_ONLY = /promotions
```

Setting these one at a time is unsafe **in both orders**, and this is worth
recording because it is not obvious:

- `AUTH_ENFORCE_ONLY` first → the boot fails. `auth.config.ts:41-48` refuses to
  start when the allowlist is set without `AUTH_ENFORCEMENT=enforce`.
- `AUTH_ENFORCEMENT` first → enforcement applies **globally** with no allowlist,
  401-ing every `@Auth` route on the fleet.

So both variables were written in **one atomic API call**, pre-flight verified
as a clean superset: all 19 existing values carried forward byte-identical, 0
altered, 0 dropped, 2 added. The prior state was captured first, and the local
copies of every secret were deleted immediately after use.

**A second finding: updating environment variables via the Render API does not
trigger a redeploy.** Polled for 10 minutes — no new deploy, uptime still 4427s,
and the exposure still open at 1034 B. The variables were stored but inert. A
deploy had to be triggered explicitly. Anyone who changes a variable and assumes
it took effect will be wrong.

## 3. Deployment

| | |
|---|---|
| Deploy | `dep-d9r0qqu7bikc73d6m6hg` |
| Commit | `809935e` |
| Status | **live** |
| Boot | `Nest application successfully started` 16:53:57 |
| Route audit | `108 routes — firebase=39 admin=46 public=23 undeclared=0 (mode=enforce)` |

The route audit is the one that refuses to start when a declared scheme and the
applied guards disagree. It passed **under `enforce`** with `undeclared=0`.

This also resolved a gap from the escrow report: the deploy API confirms the
previous live commit was `ee96d95`, so **the escrow fix was verifiably the
running code** — previously only inferable from restart timing.

## 4. Verification — measured, not inferred

### The exposure is closed

| Route (anonymous) | Before | After |
|---|---|---|
| `GET /promotions/campaigns?user_id=<real>` | **200, 1034 B of real data** | **401** `AUTH_REQUIRED` |
| `GET /promotions/payments?user_id=<real>` | **200, 546 B of real data** | **401** `AUTH_REQUIRED` |

### Legitimate access still works — proven with a real token

A Firebase ID token was minted for an **already-existing** uid (creating no
Firebase user) and used against production. No application data was written.

| Probe | Expected | Actual |
|---|---|---|
| valid token, **own** campaigns | 200 | **200** — real records returned |
| valid token, **another user's** campaigns | 403 | **403** *"The identity in this request does not match the authenticated…"* |
| no token | 401 | **401** |
| valid token, own payments | 200 | **200** |

The 403 is the important one. It is not merely that anonymous callers are now
refused — **identity binding is actively preventing one authenticated user from
reading another's data.** The server log records it precisely:

```
[AUTH][CONFLICT_DENIED] GET /promotions/campaigns —
  uid=nlAJnbHF… query.user_id=conflict(claimed=bLbPkk9w…)
```

### Everything else is unchanged

| Route | Result |
|---|---|
| `GET /feed` (anonymous) | 200, 4177 B |
| `GET /promotions/packages` (`@Public`) | 200 |
| `GET /promotions/events` (`@Public`) | 404 — same as baseline |
| `GET /promotions/slots` (`@Public`) | 400 — same as baseline, needs params |
| `GET /jobs/:id/status` | 200 — outside allowlist, unchanged |
| `GET /reviews/eligibility/:id` | 200 — outside allowlist, unchanged |
| `GET /mpesa/status/:id` | 200 — outside allowlist, unchanged |
| `GET /disputes/:id/thread` | 404 — outside allowlist, unchanged |
| `GET /admin/events` | 401 *"Missing admin bearer token"* — **AdminAuthGuard**, not AuthGuard |

Admin routes cannot be affected by `AUTH_ENFORCEMENT`: they carry
`scheme: 'admin'` and the guard returns immediately for them
(`auth.guard.ts:100-104`), leaving `AdminAuthGuard` in charge. The distinct 401
body confirms which credential system answered.

The allowlist is provably narrowing correctly — post-deploy log entries for
routes outside `/promotions` read:

```
[AUTH][WOULD_DENY] GET /jobs/…/status — reason=absent mode=enforce enforcing=false
```

`mode=enforce` with `enforcing=false` is exactly the intended state: the mode is
on, the allowlist is holding it back everywhere except `/promotions`.

### Payments, jobs, escrow, notifications

Escrow fingerprint `351c0047cd783dd30bfc8fdea0bf262a`, 17 rows, sum 73,250 —
identical to the post-migration value. Transactions 45. Notifications 225.
**Nothing moved.**

## 5. Monitoring — and an honest caveat

| Signal | Since deploy |
|---|---|
| Actual enforcement denials | 1 — my own cross-user probe |
| `WOULD_DENY` | 4 — all `ua="curl/8.21.0"`, all mine, all outside the allowlist |
| `ERROR` | **none** |
| 500s | **none** |
| uncaught exceptions / unhandled rejections / FATAL | **none** |
| Startup failures | none — clean boot |
| Restart loops | none — single deploy, stable uptime |
| Database latency | 80–133 ms, healthy |

**The caveat matters more than the numbers.** Every `WOULD_DENY` in the entire
log window — before and after — carries `ua="curl/8.21.0"` and is one of my own
probes. **There is no real user traffic to measure.** No payment traffic since
2026-06-22; the most recent user notification is 2026-07-27. A 24-hour
monitoring window will therefore be low-signal by default, and a quiet dashboard
must not be read as "enforcement is proven safe at scale". It only proves
nothing broke for a fleet that is currently idle.

That is an argument for keeping Stage 2 gated on real traffic returning, not on
elapsed time.

One transient to note honestly: the first `/health` sample after boot reported
`database: degraded`. Three follow-up samples read `healthy` at 80–133 ms. It
was a cold-start artefact of the cached dependency check, not a regression. The
persistent `degraded` overall status is `REDIS_URL` being unset — pre-existing
and unchanged.

## 6. Dead-letter events — resolved as instructed

Confirmed obsolete first: **all ten** remaining events already point at their
own transaction, so migration 110 did the escrow work they existed to do. They
were **closed administratively** (`processed = true`), with the original error
preserved in `last_error` alongside a note explaining the closure. **No handler
ran, so no notification was sent** — verified: notifications 225 total and 125
for the affected provider, both unchanged.

`deadLetterCount` went **11 → 1**.

**The safe probe event could not be replayed, and the reason is a real finding.**
`fetchUnprocessed` filters `created_at >= now() - 24h`
(`events.service.ts:139`). The probe event is dated 2026-06-09, so the
background retry loop will never select it — by design. Only `replayById`, the
admin endpoint, fetches by id and can reach an event that old, and that requires
an admin bearer token.

My initial reset therefore left it in limbo — no longer counted in
`deadLetterCount`, yet permanently unprocessable. **I restored it to its exact
prior state** (`dead_letter=true, retry_count=3`) so the remaining count of 1 is
a truthful, actionable signal rather than a hidden orphan.

Its replay value has also largely evaporated: it was proposed as a deployment
probe, and the Render deploy API now provides better proof of the running commit
than a replay would.

**Implication worth acting on:** any event that dead-letters and is not replayed
within 24 hours becomes unreachable to automation forever. That is a reasonable
guard against replaying ancient events accidentally, but it means the admin
replay endpoint is the *only* recovery path, and it is currently the one path
with no runbook.

## 7. Findings unrelated to Stage 1

**A recurring background failure.** `ReputationService` has been failing to
recompute reputation for one provider repeatedly between 2026-08-02 and
2026-08-06:

```
[REPUTATION] recompute failed for bLbPkk9w2uSX8sLbgvjw2wMBOPb2:
  insert or update on table "provider_reputation" violates foreign key constraint
```

Notable because the user **does exist** in `public.users` and the constraint
targets `users.id`, so the obvious explanation is wrong. Not investigated
further — outside Stage 1 scope, no production change made.

**Bug A is live, not historical.** Transaction `8d7630c1` (2026-08-01, KES
2,500, still `pending`) logged
`Escrow insert failed … duplicate key value violates unique constraint
"escrow_job_id_key"` — the exact optimistic-insert collision the escrow work
addressed. The now-deployed handler is what repairs this class on the next
successful payment.

**A credential is exposed in the working tree.** `.mcp.json` is tracked by git,
currently modified, and contains a live Render API key in plaintext. It is **not
yet in git history** — verified with `git log -S`. Any `git add -A` would commit
it. I deliberately did not stage it. Recommended: add to `.gitignore`,
`git rm --cached`, and rotate the key.

---

## 8. Recommendation on Stage 2

**Do not expand `AUTH_ENFORCE_ONLY` yet**, and not merely because 24 hours have
not elapsed — because there is no traffic against which the current window means
anything. The evidence that would justify Stage 2 is real authenticated requests
succeeding under enforcement, and there are none to observe today.

When traffic returns, Stage 2 adds `/mpesa`, `/jobs`, `/disputes`, `/reviews`.
Expect exactly one behaviour change, already traced: `_refreshJobStatus` in post
detail is not sign-in gated, and it degrades silently because `getJobStatus`
swallows non-200s.

Rollback for Stage 1 remains an environment change with no code deploy: set
`AUTH_ENFORCEMENT=monitor` and trigger a deploy.
