# 🏦 Engineering Roadmap — Financial Automation Phase

> **Milestone:** Financial Automation Phase (Post Production Daraja Integration)
> **Status:** ⏸️ **PAUSED — intentionally deferred until the Help24 Production Daraja API is active.**
> **Decision date:** 2026-07-12
> **Reason:** Every money movement in this phase must be validated against the **real Safaricom ecosystem** (production B2C, real callbacks, real transaction-status queries, real timeout behaviour) instead of assumptions or sandbox behaviour. Building the automation now would mean certifying it against a simulator; we will not do that for a financial rail.

**Nothing in this document is cancelled.** All design work, implementation notes, migrations, and tests referenced here are preserved in the repo and remain the agreed plan. When Production Daraja is live, this document is the entry point to resume.

---

## 1. What is already BUILT and SHIPPED (do not touch, do not delete)

These are in production/main today and are the foundation the automation phase builds on:

| Component | Where | Status |
|---|---|---|
| Payout reconciliation engine (admin-triggered, Daraja Transaction Status Query, settles only on *confirmed* result — never on elapsed time) | `backend/src/mpesa/mpesa.service.ts` (`reconcilePayout`, `handleB2cStatusResult`) | ✅ shipped |
| Single idempotent settlement writer | `backend/src/mpesa/mpesa.service.ts` (`settleByTransaction`, `settleByConversation`, `handleB2cCallback`) | ✅ shipped |
| `originator_conversation_id` tracking | migration `059`, `transactions` table | ✅ applied |
| Settlements ledger table (append-only accounting: directions `provider_payout`/`client_refund`/`platform_fee`, double-pay guard `uq_settlements_active_leg`) | `supabase/migrations/058_settlement_ledger.sql` | ✅ table exists (INERT — service_role only, no code writes to it yet) |
| Backfill + derived views + validation reports SQL | `supabase/settlement-3.4a/backfill_settlements.sql`, `views.sql`, `validation_reports.sql` | ✅ written, review-run |
| Canonical `deriveSettlementState` (10 states, archive-gate parity proven over 96 combos) | `backend/src/jobs/settlement-state.ts` + `settlement-state.spec.ts` (24 tests) | ✅ shipped |
| Truthful PARTIAL_SPLIT / FULL_REFUND handling: recorded immutably, cash settled manually, honest copy | `backend/src/admin/disputes/decisions.service.ts` | ✅ shipped |
| Archive/delete blocked while funds held (`paid`/`payout_pending`/`locked`) | `backend/src/jobs/jobs.service.ts` (`archivePost`) | ✅ shipped |
| Financial tables locked from anon (42501) | migration `060` | ✅ applied |

**Preservation rule (verbatim from product owner):** *Do NOT delete any of the existing settlement work or plans. Do not remove any implementation notes. Do not remove any tests. Do not delete any design work.*

---

## 2. What is PAUSED (the automation work itself)

### 2.1 Settlement Ledger evolution
- Promote the `settlements` table (058) from INERT to the **authoritative accounting layer**: every financial obligation written to the ledger as immutable legs *before* any money moves.
- The ledger becomes the source of truth for outstanding provider obligations; `transactions`/`escrow` become coarse operational statuses **derived** from it (`syncEscrowFromLedger`).
- Run `settlement-3.4a/backfill_settlements.sql` once (insert-only, idempotent) to seed legs for historical money; review its validation reports before/after.

### 2.2 Automated PARTIAL_SPLIT execution (the approved "A + B2C-for-owed-leg hybrid" — Phase D1)
The full implementation plan was produced and approved-in-principle on 2026-07-09. Summary (see §5 for the complete plan):
- On a PARTIAL_SPLIT decision, write ledger legs first: `provider_payout` = **owed**, `client_refund` = **recorded** (manual in D1), `platform_fee` = **retained**.
- Auto-dispatch the provider owed leg through the **existing** B2C engine (`dispatchProviderLeg` → `daraja.b2cPayout` → callback → `settleByTransaction` core). **One settlement engine — never fork a second path.**
- Feature flag `SPLIT_AUTO_PAYOUT` (on in dev, off in prod until proven; worklist button as manual fallback).

### 2.3 Automated FULL_REFUND rail (Phase D2)
- Client refunds stay **recorded/manual** until this phase. D2 builds a dedicated automated refund rail (Daraja reversal or B2C-to-client) on the same ledger architecture: `client_refund` leg `recorded → pending → succeeded/failed`.

### 2.4 Provider payout automation
- `dispatchProviderLeg(leg)` — thin wrapper over the existing `b2cPayout` (+ dev-sim) paying `leg.amount` to `leg.beneficiary`; leg `owed → pending`, stores `conversation_id`/`originator_conversation_id`, `attempts++`.
- FULL_RELEASE becomes the single-full-amount-leg case of the same mechanism (behaviour-preserving; regression test #1 guards it).

### 2.5 Client refund automation
- Phase D2 (see 2.3). Admin worklist endpoint `POST /admin/settlements/:legId/mark-refunded` (`recorded → completed`) is the D1 manual bridge until then.

### 2.6 Per-leg accounting
- Every decision produces immutable legs with `direction, rail, amount, beneficiary_user_id, reason_ref_type, reason_ref_id, environment`; B2C legs also carry `conversation_id, originator_conversation_id, mpesa_receipt, failure_reason, attempts, last_attempt_at, settled_at`.
- `deriveSettlementState` gains ledger inputs (`hasOutstandingLeg`, `providerOwed`, `providerLegFailed`); `can_archive=false` while any leg is non-terminal.
- Archive/delete unlocks **only when every obligation reaches a terminal state**.

### 2.7 Reconciliation improvements
- Extend `reconcilePayout` / `handleB2cStatusResult` to locate ledger **legs** by `conversation_id`/`originator_conversation_id` (same resolution they already use for transactions).
- Invariant preserved: settle **only on a confirmed Daraja result — never on elapsed time**.
- Admin settlement worklist: `GET /admin/settlements/outstanding` (owed provider legs + recorded client refunds; reuses `validation_reports.sql` Reports 3/4), `POST /admin/settlements/:legId/pay-provider` (senior_admin).

### 2.8 Production Daraja verification ⛔ GATE
This is the gate that pauses everything above:
- Production B2C credentials, shortcode, result/timeout URLs registered and reachable.
- Real production B2C payout observed end-to-end (dispatch → callback → receipt).
- Production Transaction Status Query verified against a real transaction.
- Production callback IP allowlisting / security validated.
- Only after this is green does the automation phase resume.

### 2.9 Settlement stress tests
- Concurrent decision + callback races; duplicate/late/out-of-order callbacks; parallel reconcile + callback on the same leg; `uq_settlements_active_leg` under concurrent dispatch attempts.

### 2.10 Financial audit tests
- Ledger completeness: every shilling in = sum of legs out (provider + refund + fee) per transaction.
- Immutability: no UPDATE that rewrites amount/direction of a terminal leg.
- Backfill validation reports re-run clean after automation writes begin.

### 2.11 End-to-end production payment verification
- Full real-money path: STK push → escrow lock → decision → ledger legs → B2C dispatch → Safaricom callback → leg settled → escrow synced → archive unlocked. Verified with small real amounts before enabling `SPLIT_AUTO_PAYOUT` in production.

### 2.12 Callback resilience testing
- Missing callback (the original stranded-payout scenario — record `6548bcdc` remains the controlled test case), delayed callback, malformed payload, retried callback, callback for unknown conversation_id.

### 2.13 Failure recovery verification
- Provider leg `failed` → unique-slot freed → admin retry via worklist; split-brain (leg vs escrow mismatch) repaired idempotently by `settleByTransaction`'s existing repair path.

### 2.14 Timeout verification
- Daraja B2C QueueTimeoutURL handling verified in production; stuck `pending` legs resolvable only via confirmed status query (2.7), never by age.

### 2.15 Production reconciliation verification
- Run `reconcilePayout` against a real production transaction; confirm status-query result parsing matches production payloads (they differ from sandbox in known fields); confirm no state change on ambiguous results.

---

## 3. Resume checklist (in order, when Production Daraja is live)

1. ✅ Gate 2.8 (Production Daraja verification) fully green.
2. Verify migration `058` applied; run backfill (2.1) + validation reports.
3. Implement D1 per §5 plan, **tests-first**, in test-matrix order (§5.10).
4. Regression: FULL_RELEASE must be byte-for-byte behaviourally identical (test #1).
5. Enable `SPLIT_AUTO_PAYOUT` in dev → verify → staged prod enable.
6. Phase D2 (automated refund rail) only after D1 is proven in production.

---

## 4. Related but SEPARATE pending items (not paused by this milestone)

- **S1** (user action): deploy `exchange-firebase-token` + set `SUPABASE_JWT_SECRET`, verify `[AUTH][BRIDGE] ok=true`.
- **S3 part 1**: apply migration `061` (private-table owner RLS) — gated on S1.
- **S3 part 2**: apply `062` (public_profiles view), switch feed author reads to `public_profiles`, then `063` users-PII lockdown.

---

## 5. APPENDIX — The approved Phase D1 implementation plan (verbatim, 2026-07-09)

> Preserved in full so no design work is lost. This is the plan to execute at resume time.

### 5.1 Architecture & guiding principles
- The `settlements` ledger (058) is the authoritative accounting layer. Every decision writes immutable legs *first*; the ledger is the source of truth for outstanding obligations.
- **One settlement engine.** The provider split payout reuses the exact B2C dispatch + `settleByTransaction` core + `handleB2cCallback` + `reconcilePayout` + `handleB2cStatusResult` + idempotency. We **augment** that engine to be ledger-aware and leg-capable — we do **not** fork a second path. FULL_RELEASE stays operationally identical (single full-amount leg); a split is just a *partial* provider leg.
- `transactions`/`escrow` remain the operational status, derived from the ledger. No new escrow enum value — nuance comes from the ledger + `decision_type`.
- Client refunds stay `recorded`/manual in D1 (Phase D2 automates them on the same architecture).
- Archive blocks while ANY leg is non-terminal; unlocks only when every obligation is terminal.
- Idempotent, auditable, test-driven. Reuse the `uq_settlements_active_leg` double-pay guard.

### 5.2 Ledger legs written per decision
On `decisions.service.applyFinancial`, write legs **before** any money moves:

| Decision | provider_payout | client_refund | platform_fee |
|---|---|---|---|
| **FULL_RELEASE** | `owed`→B2C (full amount) | — | `retained` |
| **FULL_REFUND** | — | `recorded` (manual) | `refunded` |
| **PARTIAL_SPLIT** | `owed`→B2C (`provider_amount`) | `recorded` (manual, `client_refund_amount`) | `retained` (or split) |

### 5.3 The unified engine (augment, don't fork)
- `dispatchProviderLeg(leg)` — thin wrapper over existing Daraja `b2cPayout` (+ dev-sim); leg `owed→pending`, stores conversation ids, `attempts++`. FULL_RELEASE calls it with a full-amount leg; PARTIAL_SPLIT with a partial leg. Same Daraja call, one place.
- `settleByTransaction` core generalized to settle the provider_payout LEG (`pending→succeeded` +receipt/settled_at, or `→failed` +reason) then `syncEscrowFromLedger(transaction_id)` recomputes coarse escrow/transaction status.
- `handleB2cCallback` resolves target by `conversation_id`: transaction (existing FULL_RELEASE fast-path) and/or ledger leg → same settle core. Duplicate callbacks are no-ops.
- `reconcilePayout` / `handleB2cStatusResult` extended to locate the leg by conversation ids. Never auto-release on age.
- `syncEscrowFromLedger` mapping: provider leg `pending` → escrow `payout_pending`; provider `succeeded` + no refund → `released`; provider `failed` → `locked` +reason; client refund present → `refunded` (derive surfaces `split_settled`).

### 5.4 State-transition diagram
```
DECISION (immutable legs written first)
  │
  ├─ provider_payout leg
  │     owed ──dispatchProviderLeg (B2C / dev-sim)──▶ pending
  │       pending ──handleB2cCallback ok / status-query "Completed"──▶ succeeded ✔terminal
  │       pending ──callback fail / status-query failed──────────────▶ failed ✔terminal (slot freed → admin retry)
  │       pending ──reconcilePayout──▶ (settles ONLY on confirmed result; never on elapsed time)
  │
  ├─ client_refund leg (D1: manual)
  │     recorded ──admin "mark refunded" (worklist)──▶ completed ✔terminal   (D2: auto rail later)
  │
  └─ platform_fee leg
        retained ✔terminal   |   refunded ✔terminal (FULL_REFUND)

syncEscrowFromLedger(tx):
  provider.pending                       → escrow=payout_pending   → derive: payout_processing
  provider.succeeded & no refund         → escrow=released         → derive: released
  provider.failed                        → escrow=locked +reason   → derive: settlement_failed
  client_refund present, provider done   → escrow=refunded         → derive: split_settled (until refund completed)
  ALL legs terminal                      → archive unlocked
```

### 5.5 `deriveSettlementState` changes (ledger + tx)
- New inputs: `hasOutstandingLeg` (any leg `owed/pending/recorded/initiated`), `providerOwed` (from `owed`/`pending` provider leg), `providerLegFailed`.
- Provider leg `pending` → `payout_processing`; `failed` → `settlement_failed`.
- `split_settled` persists while `client_refund` is `recorded` (attention flips `provider_payout_owed` → `client_refund_pending` once provider leg clears).
- `can_archive = false` if `hasOutstandingLeg` (in addition to existing tx/escrow gate). Parity test extended.

### 5.6 Archive change
`archivePost` adds one existence check: block if any `settlements` leg for the post is non-terminal (`status IN ('initiated','pending','owed','recorded')`). Message from `deriveSettlementState`. Enforcement only tightens.

### 5.7 Admin settlement worklist
- `GET /admin/settlements/outstanding` — owed provider legs + recorded client refunds.
- `POST /admin/settlements/:legId/pay-provider` — `dispatchProviderLeg` (senior_admin).
- `POST /admin/settlements/:legId/mark-refunded` — client_refund `recorded→completed` (audited).

### 5.8 Affected files
Backend (change): `admin/disputes/decisions.service.ts`, `mpesa/mpesa.service.ts`, new `settlements/settlements.service.ts` (+spec), `jobs/settlement-state.ts`, `jobs/jobs.service.ts`, `admin/admin.controller.ts`, `admin/admin.module.ts`.
Tests: `settlements.service.spec.ts`, `b2c-settlement.spec.ts` (partial leg), `settlement-state.spec.ts` (ledger rows), `decisions.service.spec.ts`, `lifecycle.spec.ts`, archive spec.
Mobile: none for D1 (lifecycle already renders `settlement`). Admin dashboard worklist UI optional/later.

### 5.9 Migration sequence
1. Verify `058_settlement_ledger.sql` applied (additive, safe).
2. Run `settlement-3.4a/backfill_settlements.sql` once (idempotent, insert-only); review the 4 validation reports before/after.
3. No new schema expected — 058 already supports B2C leg tracking. (Tiny optional `settled_by`/index migration TBD during build.)
4. Independent of the S1/S3 security track.

### 5.10 Test matrix
| # | Scenario | Expect |
|---|---|---|
| 1 | FULL_RELEASE (regression) | one full provider leg `owed→pending→succeeded`; escrow `released`; **identical to today** |
| 2 | PARTIAL_SPLIT dispatch | provider leg partial `owed→pending`; client_refund `recorded`; escrow `payout_pending`; state `payout_processing` |
| 3 | Split provider B2C success (callback) | provider leg `succeeded`; escrow `refunded`; state `split_settled`; archive still blocked (refund `recorded`) |
| 4 | Split provider B2C failure | provider leg `failed`; escrow reverts; state `settlement_failed`; retry via worklist |
| 5 | Duplicate callback | no double-settle, no double-notify |
| 6 | Dev-sim split | provider leg settles end-to-end via simulated callback |
| 7 | Reconcile stuck split leg | settles only on confirmed status; never on age |
| 8 | Admin mark-refunded | `recorded→completed`; if provider also done → archive unlocks |
| 9 | Idempotency | re-dispatch blocked by `uq_settlements_active_leg`; retry only after `failed` |
| 10 | Archive gate | blocked while any leg non-terminal; 96-combo parity extended |
| 11 | deriveSettlementState from ledger | every leg combination → correct state/attention/provider_owed |
| 12 | Split-brain repair | leg vs escrow mismatch repaired idempotently |

### 5.11 Rollback strategy
- Ledger writes are additive/immutable — rollback = stop writing legs; existing legs are inert accounting rows.
- Engine augmentation is behaviour-preserving for FULL_RELEASE (test #1 guards). Revert the decisions.service leg-dispatch commit to fall back.
- No destructive SQL — backfill is insert-only and idempotent.
- Feature flag `SPLIT_AUTO_PAYOUT` lets PARTIAL_SPLIT fall back to "record `owed`, settle via worklist".

### 5.12 Open decision at pause time
- `SPLIT_AUTO_PAYOUT` flag stance (recommended: on in dev, off in prod initially, flip after proven). **Not yet decided — decide at resume.**

---

## 6. Standing execution rules (carry into resume — verbatim from product owner)

- "Never auto-release funds based on elapsed time."
- "Never alter the existing archive enforcement to allow unresolved payout_pending money."
- "Do not implement Phase D financial settlement changes without an explicit policy decision from me."
- "Every financial obligation is first written to the settlements ledger as immutable accounting entries."
- "Do not duplicate settlement logic. Reuse the existing payout engine … so there is still only one settlement engine in Help24."
- "The implementation must remain idempotent, auditable, and fully test-driven."
- "no destructive data changes without showing me the exact repair SQL first."
