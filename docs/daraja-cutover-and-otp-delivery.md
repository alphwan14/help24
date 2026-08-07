# Prepared, not implemented — Daraja production cutover & OTP delivery

Status: **preparation only.** Nothing in this document is wired. It exists so
that when the external dependencies land (Safaricom production credentials, an
Africa's Talking account), implementation is a checklist and not a design
session. Companion: `launch-readiness-sprint.md` §3.

---

## 1. Daraja production payouts — waiting on Safaricom credentials

### What flips

The service already boots against SANDBOX and logs its endpoints
(`DarajaService` prints OAuth/STK/B2C URLs at boot). Cutover is environment,
not code: `MPESA_ENV=production` plus the production consumer key/secret,
shortcode, passkey, and B2C initiator credentials on Render. The `/mpesa/dev/*`
and `test-stk` surfaces already refuse when `MPESA_ENV=production`.

### Live-money test matrix (run in order, smallest amounts Daraja allows)

| # | Scenario | Verifies |
|---|---|---|
| 1 | Escrow funding (STK push, real PIN) | stk-callback path, escrow row + snapshot capture against the verified default destination |
| 2 | Payout release (full) | b2c-callback path, resolver uses the escrow snapshot, audit chain `payout_initiated → payout_completed` |
| 3 | Partial release | split arithmetic, remainder stays escrowed |
| 4 | Partial refund | refund leg + remainder release |
| 5 | Full refund | no payout leg, transaction terminal state |
| 6 | Payout reversal handling | b2c failure/reversal callback → `payout_reversed` audit event, escrow state correct |
| 7 | Reconciliation | `/admin/reconcile-payout` against Daraja transaction-status API agrees with our ledger |

Each step: verify the Render log line, the `payout_audit_events` chain, and the
Daraja portal record before moving to the next. Abort the matrix on the first
disagreement — a reconciliation gap with real money is a stop-the-line event.

### Flag order at cutover (already supported by code)

1. `PAYOUT_DESTINATIONS_ENABLED=true` (destinations + audit + HTTP surface on)
2. Watch `source=` in payout logs (snapshot vs current_destination)
3. `PAYOUT_REQUIRE_VERIFIED=true` once every live provider has an OTP-verified default
4. `PAYOUT_ALLOW_LEGACY_FALLBACK=false` once no pre-snapshot escrow remains unsettled

## 2. OTP delivery — decision recorded, sending not wired

**Decision:** Firebase Authentication keeps sign-in / sign-up phone
verification (Google delivers those codes; we never see them). Africa's
Talking will carry business/security OTPs — payout-destination verification
first — because business OTPs need controlled wording, our own sender
identity, and are outside what Firebase Auth is for.

**Where the seam is:** `backend/src/payouts/otp-delivery.ts` defines
`OtpDeliveryPort` and the `OTP_DELIVERY` injection token. The issuer
(`PayoutOtpService`) is delivery-agnostic. Today the port is bound to
`LogOnlyOtpDelivery`, which records issuance without sending (QA can set
`PAYOUT_OTP_ECHO_CODES=true` to echo codes in logs — never with real
providers).

**When the Africa's Talking account exists**, the implementation is:
1. `AfricasTalkingOtpDelivery implements OtpDeliveryPort` (API key + sender ID
   from env, one HTTP call, no retries that could double-send a code).
2. Swap the `OTP_DELIVERY` binding in `payouts.module.ts`.
3. Set `PAYOUT_OTP_PEPPER` (hash pepper) if not already set.
4. Nothing else changes: challenge schema, verify path, cooldowns, rate limits
   and the mobile UI are already final.

**Deliberately not scaffolded:** the Africa's Talking client class. An
unsendable sender is untestable code, and the port makes it a one-file drop-in.
