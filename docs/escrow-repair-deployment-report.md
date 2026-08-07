# Escrow Repair — Deployment Report

Status: **awaiting approval. Nothing applied, nothing committed, nothing pushed.**

Package under review:

| Artifact | State |
|---|---|
| `backend/src/events/event-processor.service.ts` — the fix | written, tested, **not committed** |
| `backend/src/events/escrow-lock.spec.ts` — 13 new tests | written, passing, **not committed** |
| `supabase/migrations/110_escrow_transaction_link_repair.sql` — the data repair | written, dry-run proven, **not applied** |

---

## 1. What actually went wrong — corrected diagnosis

**The audit's account of this defect was incomplete, and its proposed fix would
not have worked.** Designing before applying is what caught it. The corrected
account:

### Two bugs compounding

**Bug A — a failed payment leaves its escrow behind.**
Escrow is inserted *optimistically at payment initiate*, before the payment is
known to succeed (`mpesa.service.ts:297-310`). When that payment fails, nothing
removes the row. The post keeps a `locked` escrow row bound to a failed
transaction.

**Bug B — the repair handler could never repair anything.**
`event-processor.service.ts:224-227` upserted with `onConflict: 'transaction_id'`.
`escrow` has no unique constraint on that column — its only unique constraint is
`escrow_job_id_key UNIQUE (post_id)`. Postgres therefore rejected **every** call:

> `there is no unique or exclusion constraint matching the ON CONFLICT specification`

All eleven dead-lettered `payment.success` events carry that identical error.

### The resulting sequence, identical in all six cases

1. Payment attempt 1 → transaction created → escrow row inserted optimistically
2. Attempt 1 fails → transaction becomes `failed`; **the escrow row remains**
3. A retry is permitted — initiate only blocks on `pending`/`paid`
   (`mpesa.service.ts:156-169`) — so attempt 2 creates a second transaction, and
   **its** optimistic insert dies on `UNIQUE (post_id)`
4. Attempt 2 succeeds → `payment.success` fires → Bug B → no repair
5. **Result:** the post's escrow points at the *failed* attempt; the *successful*
   transaction has no escrow row

### Why the audit's proposed fix was wrong

The audit (§0.1) proposed adding `UNIQUE (escrow.transaction_id)`. Tested against
production inside a rolled-back transaction:

```
ALTER TABLE escrow ADD CONSTRAINT tmp UNIQUE (transaction_id);
INSERT … ON CONFLICT (transaction_id) DO UPDATE …
→ STILL FAILS: duplicate key value violates unique constraint "escrow_job_id_key"
```

The constraint makes the SQL *valid* but the INSERT still violates the
`post_id` unique constraint, because a row for that post already exists under a
different transaction. **A schema change would not have fixed the bug.**

### What is actually correct

`escrow` is one-row-per-post *by schema*. The post is the identity that matters,
and `post_id` is **already unique**. Tested the same way:

```
INSERT … ON CONFLICT (post_id) DO UPDATE …
→ SUCCEEDED · escrow rows 17 (repaired in place, no new row)
            · now points at 20bc6501-… (the funding transaction)
```

**So the code fix needs no schema change, and neither does the data repair.**

---

## 2. Impact, measured

```
escrow rows total                         : 17
  bound to a FAILED transaction           : 11   (KES 37,750)
    …of which a successful retry exists   :  6   ← the repair set
    …of which no successful payment exists:  5   ← separate cleanup, see §7
funded transactions with no escrow row    :  6
```

No money is missing and no payment is unprotected — every affected post *has* an
escrow row of the correct amount. What is broken is the **link**: escrow points
at the failed attempt, so anything that looks escrow up by transaction finds
nothing, and anything that looks it up by post finds a row whose status never
advanced.

Two rows are additionally stale in status: one post is `disputed` and one is
`payout_pending`, while both escrow rows still read `locked` — because the code
paths that would have advanced them look up escrow by `transaction_id`, and that
lookup has been failing.

**Dormant, not fixed.** No payment traffic since 2026-06-22, so the failure has
had no chance to recur. The next payment that follows a failed attempt on the
same post will reproduce it exactly.

---

## 3. The code fix

`handlePaymentSuccess` now delegates to a new `lockEscrowForPayment`, which is
explicit rather than an upsert. Four branches:

| Situation | Action |
|---|---|
| No escrow row for the post | Insert `locked` for this transaction |
| Row already points at this transaction | No-op (so a replayed event is safe) |
| Row is `released` or `refunded` | **Refuse.** Never resurrect settled money |
| Row belongs to another transaction | Re-point **only if** that transaction is `failed` or gone; otherwise log an error and refuse |

**Why not simply `onConflict: 'post_id'`?** A blind upsert also overwrites
`status` back to `locked`. Events are replayable by hand
(`POST /admin/events/replay`), and the eleven historical `payment.success` events
are sitting in dead-letter waiting to be replayed — a blind upsert could
resurrect settled money as locked. The update also carries
`.eq('transaction_id', existing.transaction_id)` as optimistic concurrency, the
same pattern `campaigns.service.ts:112-125` already uses.

**Tests:** 13 new in `escrow-lock.spec.ts`, covering every branch including the
read-error case (which must throw rather than assume "no row" and insert a
duplicate). Backend suite: **543 passing**, up from 530. `tsc --noEmit` clean.

---

## 4. The data repair — migration 110

Six `UPDATE` statements. **No inserts, no deletes, no amount changes, no schema
change.** Written as explicit literals rather than a derived query on purpose: a
one-time repair should touch exactly the rows that were reviewed, and nothing a
later payment might add.

| escrow id | post | before → after transaction | status |
|---|---|---|---|
| `eb4d5953…` | `6b8e311f…` | `982d2615…` → `20bc6501…` | locked (unchanged) |
| `c1dba5b1…` | `3a405e92…` | `5fc88353…` → `8f40ceee…` | locked (unchanged) |
| `c14bff3a…` | `7f08b6a6…` | `94278d0f…` → `827c4c9a…` | locked (unchanged) |
| `fc257cca…` | `8b4a656b…` | `f24e8e73…` → `93962229…` | locked → **disputed** |
| `b9885bd0…` | `e8625809…` | `1b0e6d40…` → `f5ede71f…` | locked (unchanged) |
| `0122736e…` | `c5acf72a…` | `6db9acaf…` → `e1bbfde8…` | locked → **payout_pending** |

The status mapping is not invented — it is read off the rows that *are* correctly
linked in production: `paid → locked`, `payout_pending → payout_pending`,
`refunded → refunded`. Amounts already match the funding transaction in all six
cases (verified), so no amount is touched.

**Guards.** A pre-flight aborts unless all six rows are still in exactly the
reviewed state. A post-flight aborts unless: zero funded transactions remain
without escrow, the row count is still 17, the amount sum is still 73,250, and
there are no duplicate transaction ids. Both run inside the migration's own
transaction, so a failed assertion rolls the whole thing back.

**Idempotent.** Every statement is guarded on the stale `transaction_id`.

---

## 5. Verification — all executed against production, all rolled back

Every dry run used a `DO` block ending in an unconditional `RAISE`, so the
rollback is guaranteed by construction rather than by remembering to type it.

| Test | Result |
|---|---|
| Repair applies | 6 rows updated (expected 6) |
| No rows created or destroyed | 17 → 17 |
| No money moved | sum 73,250 → 73,250 |
| Rows outside the repair set | fingerprint **IDENTICAL** before and after |
| Funded transactions left without escrow | **0** |
| Duplicate `post_id` / `transaction_id` after | 0 / 0 |
| Escrow-vs-transaction status mismatches after | **0** |
| Idempotency | pass 1 → 6 rows, pass 2 → 0, pass 3 → 0 |
| Audit's proposed fix (`UNIQUE (transaction_id)`) | **STILL FAILS** — `escrow_job_id_key` violation |
| Correct conflict key (`post_id`, already unique) | **SUCCEEDS**, repairs in place |
| Migration 110 verbatim, incl. its own guards | pre-flight 6/6, all post-flight assertions pass |
| **Rollback script verbatim** | **restores byte-identical original state** |

Production re-checked after every dry run: 17 rows, sum 73,250, 11 bound to
failed, 6 funded without escrow — unchanged throughout.

---

## 6. Rollback

Full script in the footer of migration 110: six guarded `UPDATE`s restoring each
row's previous `transaction_id` and `status`. Proven to restore a byte-identical
fingerprint. Idempotent for the same reason the forward migration is.

The code fix rolls back by reverting its commit; it is additive (one new private
method plus a constant) and touches no other behaviour.

---

## 7. Decisions I need from you

**a) Approve the code fix + migration 110?** They are designed to ship together —
the migration repairs history, the code stops it recurring. Either can go first;
the code fix alone is harmless, and the migration alone would be re-broken by the
next failed-then-retried payment.

**b) The five remaining orphans.** Beyond the repair set, five escrow rows
(KES ~13,000) are `locked` against payments that failed and were never
successfully retried. They represent no held money, but they *do* satisfy the
archive gate's "escrow in (locked, payout_pending)" test
(`jobs.service.ts:641-655`), so those posts cannot be archived. Options:

  1. Leave them — no user has complained; archiving is rare.
  2. Delete them — they record nothing real.
  3. Add a `void` status — most honest, but it is a CHECK-constraint change and
     touches the settlement state machine.

  My recommendation is **(1) for now**, revisited under Bug A below. I have not
  written anything for this.

**c) Bug A itself — should a failed payment clean up its escrow?** The optimistic
insert is deliberate (`mpesa.service.ts:295-296` documents it), and the repair
handler is the intended safety net. With the handler actually working, the orphan
self-heals on the next successful payment for that post. So Bug A is now
*tolerable*. Cleaning up on failure would be tidier but changes the payment
failure path, which I would rather not touch in the same change as a money
repair. **Recommendation: fix the handler now, consider Bug A separately.**

**d) One intended consequence to confirm.** Re-pointing `0122736e…` gives the
`payout_pending` transaction a matching escrow row. Settlement for that payout
would then be able to complete if a Daraja callback or an admin reconcile
arrives. Nothing runs automatically — there is no sweep over escrow — but it does
change that payout from "silently un-settleable" to "settleable". That is the
intent; flagging it so it is not a surprise.

---

## 8. Proposed order of operations, on approval

1. Commit the code fix + spec. **Do not push yet.**
2. Apply migration 110. Verify: 0 orphans, 17 rows, sum 73,250, statuses aligned.
3. Push → Render auto-deploys the code fix.
4. Re-verify production endpoints and escrow state.
5. Decide separately whether to replay the eleven dead-lettered
   `payment.success` events. With the fix deployed and the data repaired, a
   replay would be a no-op for the six repaired posts (the row already points at
   the right transaction) and would correctly insert or re-point for any other.
   Worth doing to clear the dead-letter queue, but it is a separate decision.
