# Escrow Repair — Production Verification Report

Status: **applied and verified.** Migration 110 is live, the code fix is
deployed, and every approved assertion passed.

One item is **deliberately not done** and needs a decision: the dead-letter
replay turned out not to be the no-op the deployment report called it. See §5.

| Artifact | State |
|---|---|
| `ee34bac` — the code fix + 13 tests | committed, pushed, deployed |
| `ee96d95` — migration 110 as applied | committed, pushed |
| Migration `110_escrow_transaction_link_repair` | **applied** 2026-08-07, in the Supabase ledger |
| Eleven dead-lettered `payment.success` events | **untouched — awaiting your decision** |

---

## 1. Pre-flight — production was exactly as reviewed

Before writing anything, the table was fingerprinted and compared to the state
the design was built against. Nothing had drifted in the interval:

```
escrow rows                          17
escrow amount sum                    73,250
escrow bound to a failed transaction 11
funded transactions without escrow    6
rows still in the pre-repair state     6 of 6
FULL TABLE FINGERPRINT               766df9f0be7e64aa96d7d623d5c7fe0e
```

## 2. Final dry run — the eight assertions you asked for

Executed against production inside a `DO` block ending in an unconditional
`RAISE`, so the rollback is guaranteed by construction rather than by
remembering to type it.

| # | Assertion | Result |
|---|---|---|
| 1 | exactly six escrow links change | 6 changed | **PASS** |
| 2 | no new escrow rows created | 17 → 17 | **PASS** |
| 3 | no escrow rows deleted | id-set identical | **PASS** |
| 4 | no money values change | per-row amounts identical | **PASS** |
| 5 | escrow totals remain identical | 73,250 → 73,250 | **PASS** |
| 6 | released/refunded remain immutable | `094ca78e…` → `094ca78e…` | **PASS** |
| 7 | re-running performs zero writes | pass 2 wrote 0; guard then sees 0 of 6 | **PASS** |
| 8 | rollback restores byte-identical state | `766df9f0…` → `351c0047…` → `766df9f0…` | **PASS** |

Plus the migration's own post-flight guards, all inside the same discarded
block: 0 funded transactions without escrow, 0 duplicate `post_id`, 0 duplicate
`transaction_id`, 0 escrow/transaction status mismatches, and a byte-identical
fingerprint across every row outside the repair set.

Production was re-fingerprinted immediately afterwards: `766df9f0…`, unchanged.

## 3. One structural change before applying

The migration shipped as `BEGIN; … COMMIT;`. It was applied through a runner
that supplies its own transaction wrapper, and nesting those is exactly the
situation where a post-flight assertion could fire *after* a partial write had
already committed — the one failure mode the guards exist to prevent.

It was restructured into a **single `DO` block**. One statement, therefore
atomic under psql, the Supabase CLI, or a pooled connection alike. The guards
and the six `UPDATE`s are textually unchanged; only the wrapper moved. The
restructured form was then itself dry-run verbatim — byte-identical text with a
single trailing `RAISE` appended — and parsed and executed cleanly with every
guard passing before anything was applied for real.

## 4. Applied — every result matched the prediction

| Check | Expected | Actual |
|---|---|---|
| Full-table fingerprint | `351c0047cd783dd30bfc8fdea0bf262a` | `351c0047cd783dd30bfc8fdea0bf262a` |
| Escrow rows | 17 | 17 |
| Escrow amount sum | 73,250 | 73,250 |
| Funded transactions with **no** escrow | 0 (was 6) | **0** |
| Funded transactions with **more than one** escrow | 0 | **0** |
| Duplicate `post_id` / `transaction_id` | 0 / 0 | 0 / 0 |
| Escrow-vs-transaction status mismatch | 0 | **0** |
| Settled (released/refunded) fingerprint | unchanged | unchanged |
| Rows still bound to a failed transaction | 5 | **5** |

The post-apply fingerprint is byte-identical to the value the rollback-only dry
run predicted *before anything was written*. Every previously orphaned funded
transaction now owns **exactly one** escrow row.

The five rows still bound to a failed transaction are precisely the orphan set
you ruled out of scope in Decision 3. The migration did not touch them.

### Deployment

Pushed `e186bf8..ee96d95`; Render restarted 80 seconds later (uptime 4218s →
24s). Dependencies healthy: database and Firebase `healthy`; the overall
`degraded` status is the pre-existing unset `REDIS_URL`, unchanged from the
pre-deploy baseline.

**Caveat, stated plainly:** the backend exposes no build identifier, so the
restart timing is strong evidence but not proof that commit `ee96d95` is the
running code. The definitive functional proof would be a replay — see §5 — which
is held. **Recommendation: add a commit SHA to `/health`.** Render already
provides `RENDER_GIT_COMMIT`; surfacing it makes "is the fix actually live?"
answerable in one request instead of inferable from uptime.

### No regressions

| Endpoint | Result |
|---|---|
| `GET /health` | 200 |
| `GET /config` | 200 (Phase 0 config plane intact) |
| `GET /feed?page=1&page_size=3` | 200, 4178 B |
| `GET /promotions/packages` | 200 |
| `GET /reputation/health` | 200 |
| `POST /mpesa/initiate` (empty body) | 400 — reachable, validates, **created no transaction** |

Settlement and workflow state confirmed untouched by the repair: transactions 45
rows (`84489557…`), settlements 7 rows (`42fc39ba…`), disputes 4 rows
(`62c7a6f4…`), dispute_decisions 4, payout_destinations 5. Zero escrow rows
created in the window.

**Payouts:** all 3 `payout_pending` transactions now own a matching escrow row,
with **0** status disagreements. Per your Decision 2, restoring that linkage is
the intended repair — the payout for post `c5acf72a…` moves from "silently
un-settleable" to "settleable". Nothing sweeps escrow automatically, so this
takes effect only when a Daraja callback or an admin reconcile arrives.

**Disputes:** 1 disputed transaction, escrow status agrees, 0 mismatches.

---

## 5. The dead-letter replay — stopped, and why

**My deployment report was wrong to call this a no-op.** It analysed only the
escrow side. `handlePaymentSuccess` does a second thing
(`event-processor.service.ts:236-266`): it sends the provider a push —

> **Payment Secured** — *"Funds for "…" are secured. Complete the job to receive
> your payout."*

These events are from **June 2026**. Replaying all eleven would send **ten**
notifications to `nlAJnbHFktNTYEGPPPrBE1zu0RB2` — a real, active account with 125
existing notifications, most recently 27 July. Not a test fixture.

| Event | Amount | State now | Effect of replaying |
|---|---|---|---|
| `60eb927f` | 2,500 | **refunded** | **Wrong.** Announces secured funds on a refunded job |
| `ef13e6fc` | 250 | **disputed** | Misleading — job is under dispute |
| `8bd56fd2` | 800 | payout_pending | Misleading — payout already in flight |
| `6b9b0095` | 500 | payout_pending | Misleading — payout already in flight |
| `314c7d5e` | 500 | payout_pending | Misleading — payout already in flight |
| 5 others | — | locked | Stale but not contradictory |
| `3b8401f8` | 1,500 | locked, **post deleted, no provider** | **Silent — no notification possible** |

Escrow-wise a replay is now genuinely a no-op for all eleven: the migration
repaired six, and the other five were already correctly bound. **The only
remaining effect of a replay is the notification.** Push notifications are
outward-facing and irreversible, so they are not something to send on an
approval that was granted on my "no-op" characterisation.

### Options

1. **Replay only `3b8401f8`** — provably silent (no `selected_provider_id`, post
   deleted, so the notify branch cannot fire) and escrow is already correct.
   It is also the ideal deployment probe: it fails loudly with the old
   `ON CONFLICT` error and succeeds silently under the fix. **Recommended
   regardless of what you choose for the rest.**
2. **Mark the other ten processed without running the handler** — clears the
   dead-letter queue, sends nothing. The escrow work they existed to do is
   already done. Recommended.
3. **Replay all eleven** — clears the queue and sends ten stale notifications,
   five of them contradicting the job's actual state. Not recommended.
4. **Leave all eleven** — no user impact, but `deadLetterCount` stays at 11
   permanently, which is documented as the "events need manual replay" signal
   and would mask a genuine future failure.

I cannot execute option 1 or 2 myself: `POST /admin/events/replay` requires an
admin bearer token, and minting one would itself be a security-sensitive
production write with no approval behind it.

---

## 6. Rollback, still available

Six guarded `UPDATE`s at the foot of `110_escrow_transaction_link_repair.sql`,
proven to restore fingerprint `766df9f0be7e64aa96d7d623d5c7fe0e` byte-for-byte.
Idempotent for the same reason the forward repair is. The code fix reverts with
its commit; it is additive and changes no other behaviour.

---

## 7. What is now true that was not before

- Every funded transaction owns exactly one escrow row. The count of funded
  transactions with no escrow went from 6 to **0**.
- The `payment.success` handler can actually repair escrow. It never could
  before — every call since the feature shipped was rejected by Postgres.
- Two escrow rows whose status had frozen at `locked` while their job moved on
  now read `disputed` and `payout_pending`, matching their transaction.
- A replayed `payment.success` event can no longer resurrect settled money: the
  handler refuses to touch `released` or `refunded` escrow, and re-points only
  when the incumbent transaction actually failed.
