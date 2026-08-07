# Failed-Payment Escrow Cleanup — Design for Approval

Status: **design only. Nothing implemented, nothing applied.** Per Decision 1:
automatic cleanup is not to be built until this design is approved.

Scope: the escrow rows left behind when a payment fails. Five exist today
(~KES 13,000 notional, no money held). Migration 110 deliberately did not touch
them, per Decision 3.

---

## 1. Every lifecycle that depends on optimistic escrow existence

I traced all fourteen `from('escrow')` call sites. Only **one** depends on the
row *existing* rather than on its status; the rest are keyed on a
`transaction_id` an orphan never has.

| Call site | Keyed on | Can an orphan reach it? |
|---|---|---|
| **Archive gate** `jobs.service.ts:648-655` | **`post_id` + status ∈ (locked, payout_pending)** | **Yes — this is the whole problem** |
| Settlement display `jobs.service.ts:669-677` | `latestTx.id` | No — orphan is bound to an older *failed* tx |
| Dispute freeze `disputes.service.ts:753` | `transaction_id` of the disputed tx | No |
| Payout snapshot / release / failure `mpesa.service.ts:542, 704, 772, 814, 876` | `transaction_id` of a paid/payout_pending tx | No |
| Admin refund / release `admin.service.ts:251, 288, 312` | `transaction_id` | No |
| Dispute decision `decisions.service.ts:206` | `transaction_id` | No |
| Repair handler `event-processor.service.ts:313` | `post_id` | Yes — by design; it re-points the orphan |
| Optimistic insert `mpesa.service.ts:297` | `post_id` | Yes — it collides with the orphan |

### The load-bearing detail that makes naive deletion unsafe

The archive gate blocks on transactions with status `paid` or `payout_pending`
(`jobs.service.ts:645`). **`pending` is not in that list.** So during the STK
push window — after initiate, before the callback — the *only* thing preventing
the post from being archived is the optimistically inserted `locked` escrow row.

That row is not merely an artefact. **It is the archive protection for every
in-flight payment.** Any cleanup that can delete escrow while a payment is
pending opens a hole that does not exist today:

```
T0  sweep reads orphan E (post P, points at failed tx F)
T1  user retries → initiate creates tx N with status `pending`
T2  initiate's optimistic INSERT fails on UNIQUE (post_id) — E survives, still → F
T3  sweep DELETEs E
T4  post P now has a pending payment and NO escrow row
      heldTx?     N is `pending`, not in (paid, payout_pending) → false
      heldEscrow? none                                          → false
    ⇒ P is archivable while an STK push is in flight
T5  N succeeds → payment.success → escrow inserted against an archived post
```

This is the race Decision 1 asked to be ruled out, and it is why the answer is
not "add a `DELETE` to the failure handler".

---

## 2. Design

### 2.1 Three independent guards, any one of which closes the race

**(a) No live transaction for the post.** Delete only when no transaction for
that `post_id` is in `('pending','paid','payout_pending','disputed')`. This
alone kills the interleaving above at T3, because `N` is `pending`.

**(b) Optimistic concurrency on the row.** Delete matches on both `id` **and**
the stale `transaction_id`. If the repair handler re-pointed the row between the
read and the write, the delete matches nothing — the same pattern
`lockEscrowForPayment` and `campaigns.service.ts:112-125` already use.

**(c) Grace period.** Only consider rows whose transaction failed more than
**60 minutes** ago, so no plausible STK window is ever inside the sweep set.

### 2.2 Consequence: this cannot be a PostgREST chain

Guard (a) is `DELETE … WHERE NOT EXISTS (…)`, which the PostgREST client cannot
express — and splitting it into a read then a write reintroduces exactly the
TOCTOU gap the guard exists to close. **It must be a single SQL statement**,
which means a `SECURITY DEFINER` function called as an RPC.

That is a design constraint worth stating plainly, because the obvious
implementation (a `.delete().eq(…)` chain in the failure handler) is unsafe for
a reason that is invisible at the call site.

### 2.3 Reversibility: move, don't delete

Deleting a money-adjacent row is irreversible through the API. The sweep should
be an **insert-then-delete in one statement**, landing the row in an additive
audit table first:

```sql
CREATE TABLE IF NOT EXISTS public.escrow_abandoned (
  LIKE public.escrow INCLUDING DEFAULTS,
  abandoned_at        timestamptz NOT NULL DEFAULT now(),
  abandoned_reason    text        NOT NULL,
  abandoned_tx_status text        NOT NULL
);
```

Additive, touches no existing object, and makes "put it back" a single insert.
The row is preserved, so the accounting question *"was this post ever paid
for?"* stays answerable.

### 2.4 Batch cap and observability

Cap each sweep at **20 rows** and log the count. Per the audit's "no silent
caps" rule, a sweep that hits its cap must say so, otherwise a growing backlog
reads as a healthy quiet sweep.

### 2.5 Kill switch — already built

The Phase 0/1 config plane makes this free. The sweep reads a
`kill_switches.escrow_cleanup_sweep` flag and is **fail-open in the safe
direction**: unreachable config means the sweep does not run. Turning it off is
an admin `PATCH`, no redeploy, no APK.

---

## 3. Alternative considered and rejected

**Loosen the archive gate instead** — teach it to ignore escrow whose
transaction is `failed`. Read-side only, no migration, no data change, no race
by construction. Genuinely tempting, and I want to record why I am not
recommending it.

Both approaches have the same effect on the gate. The difference is blast
radius. Deletion is a one-time reviewed action on a **known set that has been
positively established as bogus**, with an audit row behind it. Gate-loosening
is a **permanent rule applied to every future row**, including ones nobody has
looked at. If a transaction is recorded `failed` but the money actually moved at
Daraja — a settlement mismatch, not a hypothetical, given this codebase has
already produced one link defect — the escrow row is the last surviving record
that funds may be held. A permanent rule that ignores that class converts a data
defect into a money-loss path; a reviewed deletion does not.

The gate's strictness is a real safety property. Fix the data, keep the gate.

---

## 4. Recommended sequence, on approval

1. **Migration**: `escrow_abandoned` audit table. Additive, idempotent,
   rollbackable, dry-run proven.
2. **RPC**: `sweep_abandoned_escrow(p_limit int)` — one statement, all three
   guards, returns the rows it moved.
3. **Dry run** against production in rollback-only form over the five known
   orphans. Verify: exactly 5 moved, escrow drops 17 → 12, sum drops by exactly
   their amounts, no row with a live transaction is touched, rollback restores a
   byte-identical fingerprint.
4. **Manual invocation first.** Run the RPC by hand, on approval, for the five.
   Confirm the five posts become archivable and nothing else moves.
5. **Only then** wire the periodic task, behind the kill switch, and watch it
   for a week before trusting it.

Steps 1–4 need no scheduler at all. If the sweep never becomes automatic, the
five orphans are still cleared and the mechanism exists for the next occurrence.

**Not recommended: cleaning up inside the payment-failure handler.** It puts a
deletion on the payment path, where a bug is maximally expensive, to save a
sweep that runs where a bug is cheap. It also cannot express guard (a) without
a second round trip.

---

## 5. What I am NOT proposing

- No change to the optimistic insert at initiate. It is deliberate, it is
  documented, and it is the archive protection for in-flight payments (§1).
- No `void` escrow status. That is a CHECK-constraint change plus a settlement
  state-machine change, for a state the audit table already records.
- No change to the archive gate (§3).
- No broadening beyond the five orphans, per Decision 3.
