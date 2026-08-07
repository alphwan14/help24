# Phase 2B — Implementation Plan

Status: **plan only. Nothing implemented. Awaiting explicit approval.**

Phase 2A shipped (`964c980`, live 2026-08-07 17:47:51 UTC). 2B is the next
band: backend-only operational controls, no Flutter release, no Render
configuration change, and — with one exception that is called out explicitly —
no migration.

Ordered as requested. The ordering is also the recommended build order, because
items 1 and 2 are diagnostics that make items 3–6 measurable, and shipping a
tuning knob before you can see what it does is how a knob gets turned wrongly.

---

## 2B-1 · Build identifier exposed through `/health`

**Why it belongs on the backend.** It is not a client concern at all. It is the
answer to "is the fix actually live?", which today can only be inferred from
uptime or answered by calling the Render API with a privileged key.

**Evidence it is needed.** During the escrow deployment I could not prove which
commit was running. The report had to carry the caveat *"restart timing is
strong evidence but not proof."* Later, the Render deploy API supplied the
answer — but that requires an API key most responders will not have during an
incident.

**Design.** `RENDER_GIT_COMMIT` is already present in the Render runtime.
Surface it on `/health`, alongside the existing dependency block:

```jsonc
{
  "status": "degraded",
  "service": "help24-backend",
  "build": {
    "commit": "964c980",           // process.env.RENDER_GIT_COMMIT ?? 'unknown'
    "deployedAt": "2026-08-07T17:47:51Z",
    "startedAt":  "2026-08-07T17:47:41Z"
  },
  "dependencies": { }
}
```

Read once at boot into a frozen object — never per request.

| | |
|---|---|
| **Deployment risk** | Very low. Additive field on an existing `@Public` response |
| **Rollback** | Revert the commit. Nothing consumes the field |
| **Operational value** | **High** — turns "which code is live?" from a privileged API call into one anonymous request |
| **Requires** | **Backend only.** No migration, no Flutter, no Render config (the variable already exists) |

**One security note.** `/health` is `@Public`. A commit SHA is not a secret —
the repository is the source of truth for what it contains — but if the
repository is private and should stay that way, expose the **short** SHA and
nothing else: no branch name, no deploy URL, no environment variable dump.

---

## 2B-2 · Dead-letter observability

**Why it belongs on the backend.** The client cannot see the outbox at all.
This is purely an operator surface.

**Evidence it is needed — this is not a tuning knob, it is a trap.**
`fetchUnprocessed` filters `created_at >= now() - 24h`
(`events.service.ts:139`). Any event that dead-letters and is not replayed
within 24 hours becomes **permanently unreachable to automation**; only the
admin replay endpoint can fetch it by id. I hit this directly: the June probe
event could not be replayed, and my reset briefly stranded it — no longer
counted in `deadLetterCount`, yet impossible to process.

Worse, `deadLetterCount` alone is documented as the "events need manual replay"
signal, and it says nothing about *age*. Eleven events sat dead-lettered since
June and the number looked the same on day 1 as on day 60.

**Design.** Extend `/health/events` (already `@Public`, already counters-only,
never payloads):

```jsonc
{
  "processorAlive": true,
  "queueSize": 0,
  "deadLetterCount": 1,
  "deadLetterOldestAt": "2026-06-09T10:14:02Z",   // new
  "deadLetterOldestAgeHours": 1423,                // new
  "deadLetterBeyondReplayWindow": 1,               // new — the ones automation can never reach
  "replayWindowHours": 24                          // new — makes the trap visible
}
```

`deadLetterBeyondReplayWindow` is the important one. It is the count of events
that are now recoverable *only* by hand.

**Sequencing note.** Make the window visible **before** making it configurable.
A configurable window whose effect nobody can observe is a worse position than
a fixed one.

| | |
|---|---|
| **Deployment risk** | Very low. Two extra aggregate reads on an admin-adjacent health route |
| **Rollback** | Revert. No consumer depends on the fields |
| **Operational value** | **High** — converts a silent permanent-loss path into a visible number |
| **Requires** | **Backend only.** No migration, no Flutter, no Render config |

---

## 2B-3 · Event retry budget configuration

**Why it belongs on the backend.** `MAX_RETRIES = 3` and
`RETRY_INTERVAL_MS = 60_000` (`event-processor.service.ts:10-11`) are
incident-time levers. During the escrow incident these were exactly the numbers
that mattered, and changing either meant a deploy.

**Design.** A `system_settings`-style document read through the same
merge-over-compiled-defaults service pattern as `feed_settings` and
`app_settings`. **Reuse `app_settings`** with a server-only key — it already
exists, and `AppConfigService` already proves a server-only row can never leak
to clients, because the `/config` response is *built from the contract* rather
than from the table.

```ts
// server-only; NOT in CLIENT_CONFIG_KEYS, so /config can never serve it
'ops.events': {
  max_retries: 3,
  retry_interval_seconds: 60,
  replay_window_hours: 24,   // pairs with 2B-2
}
```

Clamp on read: `max_retries` 1–10, `retry_interval_seconds` 10–3600,
`replay_window_hours` 1–720. A misconfigured retry loop is a self-inflicted
denial of service against your own database, so the clamps are not optional.

The interval is read by a `PeriodicTask` started once at boot. Changing it must
either restart the timer or be documented as "effective at next deploy" — the
former is better, and is a small change to `PeriodicTask`.

| | |
|---|---|
| **Deployment risk** | Low–medium. Touches the outbox loop, which is money-adjacent |
| **Rollback** | Delete the `ops.events` row → compiled defaults resume within the cache TTL. No deploy |
| **Operational value** | **High** at incident time, near zero otherwise — which is exactly when a deploy is most expensive |
| **Requires** | **Backend only.** No migration (`app_settings` exists), no Flutter, no Render config |

---

## 2B-4 · Dispute SLA configuration

**Why it belongs on the backend.** `AUTO_ESCALATE_AFTER_DAYS = 3` and
`SWEEP_INTERVAL_MS = 30 min` (`sla.service.ts:15-16`) are policy, not
engineering. An SLA is a commitment to users and may need to change with
staffing, volume, or a support backlog. None of that should require a release.

Pair it with the dispute abuse control — `RATE_LIMIT_MAX_PER_WINDOW = 5` per
24 h (`disputes.service.ts:25-26`) — which needs tuning against real abuse
patterns that have not appeared yet.

```ts
'ops.disputes': {
  auto_escalate_after_days: 3,
  sweep_interval_minutes: 30,
  rate_limit_max_per_window: 5,
  rate_limit_window_hours: 24,
}
```

**One caution.** Loosening the rate limit is an abuse-surface change. Clamp
`rate_limit_max_per_window` to a ceiling (say 50) so a fat-fingered value cannot
disable the control entirely. Tightening should always be permitted; loosening
should be bounded.

| | |
|---|---|
| **Deployment risk** | Low |
| **Rollback** | Delete the row → defaults resume. No deploy |
| **Operational value** | Medium — real but infrequent |
| **Requires** | **Backend only.** No migration, no Flutter, no Render config |

---

## 2B-5 · Cache TTL operational tuning

**Why it belongs on the backend.** These govern the memory-versus-freshness
trade-off on an instance that is currently on Render's **free** plan with a
single instance. Right-sizing them is an operational decision that changes with
plan and traffic.

| Constant | Location | Default |
|---|---|---|
| `REGISTRY_TTL_MS` | `viewer-context.service.ts:23` | 10 min |
| `VIEWER_TTL_MS` | `viewer-context.service.ts:24` | 5 min |
| `VIEWER_CACHE_MAX` | `viewer-context.service.ts:26` | 5,000 entries |
| `CACHE_TTL_MS` (feed settings) | `feed-settings.service.ts` | 60 s |
| `CACHE_TTL_MS` (app config) | `app-config.service.ts:37` | 60 s |
| `CACHE_TTL_MS` (routes) | `routes.service.ts:57` | 60 s |

**Do not migrate the config-plane TTLs blindly.** `app-config.service.ts`'s own
TTL governs how quickly a *configuration change* takes effect — including a
change to itself. Making it remotely settable creates a value that can lock out
its own correction: set it to 24 hours by mistake and you wait 24 hours to fix
it. **Clamp it hard (≤ 300 s) or leave it compiled.** I lean to leaving it
compiled; the others are safe.

`VIEWER_CACHE_MAX` is the highest-value entry — it is the memory ceiling, and
memory is the constraint that actually bites on a free instance.

| | |
|---|---|
| **Deployment risk** | Low, with clamps. Medium without |
| **Rollback** | Delete the row → defaults resume |
| **Operational value** | Medium — rises sharply if the instance starts hitting memory limits |
| **Requires** | **Backend only.** No migration, no Flutter, no Render config |

---

## 2B-6 · Background worker operational controls

**Why it belongs on the backend.** Every periodic loop in the system is
currently unconditional. There is no way to pause one. During the escrow
incident, being able to stop the event processor while inspecting state would
have been genuinely useful, and the only available lever was "redeploy" or
"suspend the whole service".

**Loops in scope**

| Loop | Cadence | Where |
|---|---|---|
| Event retry | 60 s | `event-processor.service.ts:55` |
| Dispute SLA sweep | 30 min | `sla.service.ts:32` |
| Promotions sweep | — | `promotions-sweep.service.ts` |
| Health snapshot | 15 s | `health.service.ts:64` |

**Design.** Per-loop enable switches with **fail-open** semantics, matching the
kill-switch convention already established: absent or unreachable configuration
means **enabled**, because a config outage must never silently stop the outbox.

```ts
'ops.workers': {
  event_retry_enabled: true,
  dispute_sla_enabled: true,
  promotions_sweep_enabled: true,
}
```

The switch is checked **at the top of each tick**, not at boot, so it takes
effect within one cadence with no restart. Each loop logs a single line when it
first observes itself disabled, and again when re-enabled — a silently paused
worker is worse than no switch at all.

**Do not add a health-snapshot switch.** Disabling the thing that reports
whether the service is healthy is a foot-gun with no legitimate use.

| | |
|---|---|
| **Deployment risk** | Medium — the highest in 2B. A worker wrongly disabled stops the outbox, and the outbox moves money |
| **Rollback** | Set the flag back, or delete the row → fail-open restores every loop within one cache TTL. No deploy |
| **Operational value** | High during an incident, zero otherwise |
| **Requires** | **Backend only.** No migration, no Flutter, no Render config |

**Mitigation worth building alongside:** surface each worker's enabled state in
`/health/events` and `/health`, so a paused worker is visible in the same place
someone looks when something seems stuck.

---

## Summary

| # | Item | Risk | Value | Backend only | Migration | Flutter | Render config |
|---|---|---|---|---|---|---|---|
| 2B-1 | Build identifier on `/health` | Very low | High | ✅ | ✗ | ✗ | ✗ |
| 2B-2 | Dead-letter observability | Very low | High | ✅ | ✗ | ✗ | ✗ |
| 2B-3 | Event retry budget | Low–med | High (incident) | ✅ | ✗ | ✗ | ✗ |
| 2B-4 | Dispute SLA + abuse limit | Low | Medium | ✅ | ✗ | ✗ | ✗ |
| 2B-5 | Cache TTL tuning | Low* | Medium | ✅ | ✗ | ✗ | ✗ |
| 2B-6 | Worker controls | Medium | High (incident) | ✅ | ✗ | ✗ | ✗ |

\* with clamps, and excluding the config plane's own TTL.

**No item in 2B requires a migration, a Flutter release, or a Render
configuration change.** Every one reuses `app_settings`, which already exists
and is already proven not to leak server-only keys to clients.

## Recommended build order

1. **2B-1 + 2B-2 together** — pure diagnostics, no behaviour change, and they
   make everything after them measurable. One commit, one deploy.
2. **2B-3** — the retry budget, now observable thanks to 2B-2.
3. **2B-4 + 2B-5** — policy and tuning, low risk, batchable.
4. **2B-6 last** — the highest-risk item, shipped once the observability to
   detect a wrongly-paused worker already exists.

## Verification standard for each

Unchanged from 2A, because it caught two real defects there:

- `tsc --noEmit` clean; full suite green; new tests for every branch.
- **Boot the application under `AUTH_ENFORCEMENT=enforce`** and confirm route
  count, `undeclared=0`, and **zero DI errors**. Unit tests do not exercise the
  Nest injector.
- Confirm compiled defaults produce byte-identical behaviour before any row is
  written — every item must be inert until deliberately activated.
- Fingerprint the affected table before and after.
- Production probe after deploy; report measured values, not inferences.
