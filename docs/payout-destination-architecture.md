# Payout destinations: separating "where money goes" from "who you are"

**Status: DESIGN ONLY. Nothing here is implemented.** Written 2026-08-07,
immediately after migration 103 closed the ability for an anonymous caller to
rewrite `users.phone_number`.

---

## 1. The problem migration 103 did *not* solve

Migration 103 stopped an *unauthorised* party rewriting a payout number. It did
nothing about the deeper issue, which is that **the payout destination is a
profile field at all**.

`MpesaService.startPayout` reads it directly and pays it:

```ts
.from('users').select('phone_number').eq('id', post.selected_provider_id)
→ normalizePhone(...) → daraja.b2cPayout({ phone: providerPhone, ... })
```

`users.phone_number` is simultaneously:

* a **contact detail**, edited casually from Profile, changed when someone gets
  a new line, shown in disputes and admin screens;
* a **destination for money**, read at settlement with no second source of
  truth.

Those two things have opposite requirements. A contact detail should be easy to
change. A payout destination should be hard to change, provably owned, and
should carry a record of who changed it and when. One mutable column cannot be
both.

### What is still wrong today, after 103

| Risk | Why 103 does not address it |
|---|---|
| Account takeover → payout theft | A stolen session is now the *only* thing needed. Change the number, get paid. There is no second factor and no delay. |
| Typo / wrong number | Nothing verifies the number is reachable, let alone that the provider controls it. Money goes to a stranger, irreversibly (M-Pesa B2C does not reverse). |
| No audit trail | `phone_number` is overwritten in place. After a disputed payout there is no record of what it was, when it changed, or from what device. |
| Race at settlement | The number is read *at payout time*. A change between "job approved" and "payout starts" silently redirects a payment the provider already earned. |
| Escrow disputes | An arbitrator cannot answer "was this the number the provider had when the job was accepted?" because that history does not exist. |

The last two matter most for a marketplace holding escrow: the value of an
escrow system is that the terms are fixed when the parties agree. A mutable
payout field means one party can change a term after the fact.

---

## 2. Target model

Introduce a **payout destination** as a first-class, verified, append-only
record. `users.phone_number` reverts to being what its name says: a contact
number.

```
public.payout_destinations
  id                uuid primary key
  user_id           text not null references public.users(id)
  channel           text not null check (channel in ('mpesa'))
  msisdn            text not null                 -- E.164, normalised on write
  verified_at       timestamptz                   -- NULL until OTP is proven
  verification_id   text                          -- provider's challenge handle
  status            text not null                 -- pending | active | retired
  created_at        timestamptz not null default now()
  retired_at        timestamptz
  created_by_uid    text not null                 -- who added it
  created_ip        inet
  created_device    text
```

Rules the schema itself should enforce:

* **At most one `active` destination per (user_id, channel)** — partial unique
  index `WHERE status = 'active'`.
* **A destination can never be edited.** No UPDATE of `msisdn`, ever. Changing
  your number means inserting a new row and retiring the old one, so the history
  is the table. `status` and `retired_at` are the only mutable columns, and only
  via a `SECURITY DEFINER` function.
* **`verified_at IS NULL` ⇒ unusable.** Payout selects `WHERE status='active'
  AND verified_at IS NOT NULL`.
* **RLS**: a user may INSERT their own pending row and SELECT their own rows.
  They may **not** set `verified_at` or `status` — those move only through the
  verification RPC, which runs as `service_role`. This is the same shape as
  migration 098's privileged-column guard, and for the same reason: the client
  must not be able to assert the thing that makes the record trustworthy.

### Why OTP, specifically

The provider must prove *control of the line*, not merely knowledge of the
number. An OTP to the destination MSISDN is the cheapest proof that the money
will arrive somewhere the provider can actually reach. It also converts a silent
takeover into a visible event: an attacker who has the session still cannot
complete verification without the victim's SIM.

### Escrow binding — the part that closes the race

At the moment a provider is selected for a job, **snapshot the destination id**
onto the escrow/job row:

```
posts.selected_payout_destination_id  uuid references payout_destinations(id)
```

Settlement then pays *that* destination, resolved at selection time, not
whatever is current at payout time. A provider who changes their number
mid-engagement gets the new number on the *next* job, not this one. This is the
single change that makes the terms of an escrow fixed when the parties agree.

---

## 3. Migration path (four phases, each independently safe)

**Phase 1 — additive.** Create `payout_destinations`, its indexes, RLS and the
verification RPC. Backfill one `active` row per user from their current
`users.phone_number`, with `verified_at = NULL` and a `legacy` provenance
marker. Nothing reads it yet. Zero behaviour change.

**Phase 2 — dual-read, prefer verified.** `startPayout` resolves in order:
verified active destination → legacy destination → `users.phone_number`. Log
which source answered. This is the phase where you learn how many providers have
a payout number at all, and it changes nothing for them.

**Phase 3 — verify the backfilled numbers.** Prompt each provider once, in-app,
to confirm their payout number by OTP. Until they do, they keep being paid via
the legacy path — **do not hold anyone's money hostage to a migration**. Track
the verified percentage; this is the gate for phase 4.

**Phase 4 — cut over.** `startPayout` requires a verified active destination and
refuses otherwise with a clear, actionable message. Drop the fallback. At this
point `users.phone_number` stops being read by the payment path entirely and can
be documented as contact-only.

A sensible phase-4 gate: ≥95% of providers who have completed a job in the last
90 days have a verified destination, and the remainder have been contacted.

---

## 4. Decisions that need a human, not a default

* **Cool-off on change.** Should a newly verified destination be usable
  immediately, or after a delay (24–72h) during which pending payouts still go
  to the previous one? A delay is the standard anti-takeover control; it also
  annoys legitimate providers who changed numbers precisely because the old one
  is dead. My recommendation: no delay, but **notify the old number and the
  account email on every change**, which catches takeover without penalising the
  honest case.
* **Who may retire a destination.** Owner only, or owner + admin? Admin
  retirement is useful for support, and is also an insider-risk path. If
  allowed, it must be an audited admin action, never a bare table write.
* **Non-M-Pesa channels.** `channel` is in the schema so bank/paybill can be
  added without another migration, but each brings its own verification story.
  Do not build them speculatively.
* **What happens to an in-flight payout when a destination is retired.** The
  escrow snapshot above answers this, but it should be stated in the payout
  terms the provider agrees to.

---

## 5. What this is worth

The immediate exposure is closed — 103 did that. This design addresses the
residual class: *a payout destination that anyone with the session, including
the legitimate owner acting carelessly, can change silently and untraceably at
any moment, including after the work is done.*

For a marketplace that holds other people's money in escrow, "where the money
goes" deserves the same treatment as identity itself: verified once, changed
deliberately, and recorded permanently.

Related: `supabase/migrations/103_users_update_owner_only.sql`,
`backend/src/mpesa/mpesa.service.ts`, `docs/production-hardening-plan.md`.
