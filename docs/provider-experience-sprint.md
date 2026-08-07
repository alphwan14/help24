# Provider Experience Sprint — plan only

Status: **planning document. No production changes. No SMS is sent.**
Adopted 2026-08-08, immediately after the backend architecture freeze
(`launch-readiness-sprint.md` §0 — the freeze is now in force; deploy `010bd63`
verified live). Everything here is client UX or prepared integration work; the
only backend item (SMS delivery) is one class behind an existing port.

## 1. Scope

The backend contract for the whole sprint already exists and is deployed
(flag-gated). This sprint makes the provider journey feel finished:

| # | Item | Surface | Notes |
|---|---|---|---|
| P1 | Onboarding polish | `provider_onboarding_screen.dart` | copy pass, step animations, entry from the provider gate sheet (`provider_gate.dart`) in addition to the Account tab |
| P2 | Business profile completion | `professional_profile_screen.dart` | close the gap between "profession chosen" and "profile a client trusts": bio, photo, service tags; reuse `ProfileCompletion` |
| P3 | Payout destination UX | `payout_destinations_screen.dart` | empty→first-add flow tightening, retired-history collapse, biometric gate before revealing full numbers (match `_PaymentSettingsSheet` precedent) |
| P4 | OTP UX | `payout_otp_screen.dart` | autofill from SMS (`AutofillHints.oneTimeCode` already wired), paste handling, reduced-motion fallback for the shake, voice-over labels |
| P5 | Empty states | all three new screens | every empty/error/offline state uses `loading_empty_offline.dart` widgets with copy that says what to DO next |
| P6 | Success flows | verify → "you're payable" moment | one celebratory terminal screen; onboarding hub flips to the all-done state without a manual refresh |
| P7 | SMS delivery | backend, one class | see §2 — the only item that touches the backend, allowed under the freeze as a business requirement |

## 2. Africa's Talking integration — prepared, not sent

**Ownership split (decided, recorded in `daraja-cutover-and-otp-delivery.md`):**
- **Firebase Authentication**: sign-in, sign-up, authentication phone verification. Unchanged, forever.
- **Africa's Talking**: payout verification OTP, business verification OTP, future transactional SMS (receipts, dispute notices).

**The seam already deployed:** `backend/src/payouts/otp-delivery.ts` —
`OtpDeliveryPort` + `OTP_DELIVERY` token, currently bound to
`LogOnlyOtpDelivery`. The issuer, challenge schema, cooldowns, rate limits and
the mobile UI are final; delivery is the only missing piece.

**Implementation checklist (when the AT account exists):**
1. Env (Render): `AT_API_KEY`, `AT_USERNAME`, `AT_SENDER_ID` (alphanumeric
   sender registered with AT), plus `PAYOUT_OTP_PEPPER` if still unset.
2. `AfricasTalkingOtpDelivery implements OtpDeliveryPort` — one POST to the AT
   SMS API, 10s timeout, **no retry** (a retry can double-send a code; the user
   taps resend instead), never log the code, mask the msisdn in logs.
3. Swap the `OTP_DELIVERY` binding in `payouts.module.ts`.
4. Message template (≤160 chars, no marketing):
   `Help24: Your payout verification code is {code}. It expires in 5 minutes. Never share this code — Help24 staff will never ask for it.`
5. Sandbox test against AT's simulator, then one live SMS to the operator's own
   phone, then enable `PAYOUT_DESTINATIONS_ENABLED=true` (separate, approved
   env change) and run one real onboarding end-to-end.
6. Cost guard: the `payout:issue` policy (5/hr/uid, 15/hr/IP) is the SMS spend
   ceiling; revisit only with production evidence of legitimate users hitting it.

**Not in this sprint:** delivery receipts/webhooks, SMS analytics, templated
campaign messaging. No production evidence asks for them.

## 3. Order of work

1. P5 empty states + P3 payout UX (they share screens; do together)
2. P1 onboarding polish + P6 success flows
3. P2 business profile completion
4. P7 SMS (blocked on the Africa's Talking account — start the account
   registration now, it has lead time for sender-ID approval in Kenya)

## 4. Freeze reminder

Production evidence overrides architectural intuition. Nothing in this sprint
adds backend infrastructure; if an item seems to need it, first show the log
line, metric, or user report that proves the problem exists.
