# Help24 — Launch Readiness Sprint

Status: **active. This document replaces the Phase roadmap**
(`architecture-audit-and-roadmap.md` §2+ and `phase2b-implementation-plan.md`
are retired as planning instruments; they remain as history).

Adopted: 2026-08-07, after a production verification audit run against the live
Render service (`help24-backend`, srv-d7mjm2v7f7vs73f8qaqg) — not against the
repository.

---

## 0. The rule change

Backend architecture work is **over**. From this point, a backend change is
justified only by one of:

1. a real user reporting a problem,
2. a launch blocker,
3. a production bug with log/DB evidence,
4. a security issue.

No speculative architecture. No future-proofing. No new abstraction unless a
production incident demonstrates the need. Anything not on this list is out of
scope until after launch.

## 1. Why the rule change is safe — production evidence (2026-08-07)

All observations from Render logs/metrics and the live database, window
2026-07-09 → 2026-08-07 (30 days):

| Signal | Evidence |
|---|---|
| Crashes / OOM / unhandled exceptions | **0** in 30 days |
| 5xx responses | **0** in the request logs (7-day window) |
| Error-level log lines | **12 total in 30 days**, all explained (see §4) |
| Event queue | processor alive, `queueSize=0`, 1 stale dead letter from 2026-06-09 |
| Escrow consistency | 17 escrow rows; **0** funded transactions missing an escrow row (June defect repaired by migration 110) |
| Memory / CPU | 70–127 MB of 512 MB; ~0.1% CPU |
| Boot | route audit: 111 routes, `undeclared=0`; admin self-check: bootstrap disabled, 3 real admins; graceful SIGTERM drain observed in logs |
| Deploys | live = `964c980` (repo HEAD); 1 failed deploy in history, retried successfully within a minute |
| Health | `/health` = degraded **only** because `REDIS_URL` is unset; database 123 ms, Firebase 43 ms |

Verdict: the backend is architecturally and operationally mature for an MVP
launch. Remaining work is configuration, client integration, and product
completion — not architecture.

## 2. Launch blockers (the sprint)

| # | Item | Where | Status |
|---|---|---|---|
| ~~B1~~ | ~~Mobile `ApiConfig` points at a dev-laptop LAN IP~~ | mobile-app | **WITHDRAWN — was never true.** `api_config.dart:22` defaults to the production origin; a no-flag release APK on a real device talked to production throughout the 2026-08-08 device verification |
| B2 | Provider onboarding flow (registration → payout destination → verification state → completion) | mobile-app | this sprint (Part 5) |
| B3 | OTP payout-verification UI (add destination, request/enter/resend OTP, expiry, default selection) | mobile-app | this sprint (Part 6) |
| B4 | `REDIS_URL` unset on Render → rate limiting per-instance; set it, then `REDIS_REQUIRED=true` so misconfiguration fails the deploy instead of degrading silently | Render env | open (env change, needs approval) |
| B5 | **Auth enforcement is narrowed to `/promotions` — now the top pre-payout blocker.** Device verification proved every real-client request carries `userIdSource:"verified"` with zero would-denies, so widening is safe; and proved an unauthenticated caller reaches `/payout-destinations` asserting any uid. **`/payout-destinations` must be enforced and re-probed to 401 BEFORE `PAYOUT_DESTINATIONS_ENABLED=true`** — see `launch-readiness-verification-report.md` §C1 | Render env | **ready to widen** |
| B6 | Firebase client config: SHA-256 fingerprint, authorized domains, Play Integrity, release signing key (release currently signed with the debug key) | Firebase console / app signing | owed (user action) |
| B7 | Render plan free → paid before real users: free tier spins down on idle (UptimeRobot masks it today) and payments should not run on a best-effort instance | Render | decision owed |

## 3. Prepared but NOT implemented (waiting on external dependencies)

### 3.1 Daraja production payouts — wait for Safaricom production credentials

When credentials arrive, implement and test with live money:
escrow funding, payout release, partial release, partial refund, full refund,
payout reversal handling, reconciliation. The service already boots in SANDBOX
mode and logs its endpoints; the switch is credential + env driven.

### 3.2 OTP delivery — decision framework prepared, no SMS wired

Split adopted (architecture only, no sending yet):

- **Firebase Authentication** keeps sign-in / sign-up phone verification.
- **Africa's Talking** will carry business/security OTPs (payout destination
  verification and anything else unrelated to Firebase sign-in).

The backend OTP challenge flow stays delivery-agnostic behind a delivery
interface; Africa's Talking becomes one implementation when we wire it.

## 4. Production bugs backlog (small, evidence-backed)

| # | Bug | Evidence | Class |
|---|---|---|---|
| P1 | `GET /reputation/health` (uptime probes) is parsed as `providerId="health"` and triggers a reputation recompute that fails its FK — recurring error-log noise | 2 error lines on 2026-08-07 | acceptable for MVP, cheap guard |
| P2 | Stale dead letter from 2026-06-09 (`payment.success`, the old escrow ON CONFLICT defect) — replay or mark resolved now that escrow is consistent | `deadLetterCount=1` at `/health/events` | informational |
| P3 | `founder@help24.app` bootstrap admin row removal | inactive since hardening; nothing depends on it | approved for removal (production write pending approval) |

Resolved by evidence, no action: the Aug 2–6 reputation FK errors for one uid
stopped the second the user's row was created (2026-08-06 22:13:15) — a
creation race, self-healed; and the Aug 1 escrow duplicate-key line was the
designed fallback path doing its job.

## 5. What we explicitly will NOT do

- No schema redesigns.
- No new backend modules, queues, or abstraction layers.
- No rewrites of working flows (feed, auth binding, escrow, promotions).
- No configuration plane extensions beyond what Phase 0/1 shipped.

## 6. Definition of launch-ready

1. B1–B7 closed (or B7 consciously accepted).
2. Daraja production money matrix passed (§3.1) once credentials exist.
3. Auth enforcement fully on with zero real-client would-denies.
4. One end-to-end dogfood: register provider → verify payout destination →
   fund a job → release payout → review, on production infrastructure.
