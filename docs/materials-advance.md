# Materials Advance

Status: **live and switched off** (backend `18547e6`, app Patch 5, both 2026-11-11).
Migration 139 applied 2026-11-11 with the owner's approval via `supabase db query --remote`
(the MCP apply prompt was declined twice); verified in the catalog (RLS on, no anon or
authenticated grants or policies, 0 rows) and from outside (app key gets 401 / 42501).
The backend reads `MATERIALS_ADVANCE_ENABLED` and it is not set, so nobody is offered an advance.

## What it is

Fundis ask to be paid directly on big jobs mostly because they need money for
materials before they can start. Materials Advance answers that need inside Help24:

1. On a job of **KES 10,000 or more** with a **verified provider** (approved ID check),
   the payment screen offers a switch: *Materials Advance*.
2. The customer pays **once**: the job plus the usual payment protection fee
   (5%, minimum KES 30, maximum KES 1,000). There is no extra charge; Help24 carries
   the cost of the second M-Pesa payout.
3. When the fundi is ready to buy materials, the customer opens the job and taps
   **Send materials money**. Help24 pays **40%** of the job to the fundi's M-Pesa.
4. Help24 keeps holding the other 60% until the job is approved, then pays it as the
   normal final payout.

## Owner decisions (2026-11-10)

| Question | Decision |
|---|---|
| When is the 40% sent? | Only when the customer taps Send. Never automatically. |
| Who can receive it? | Verified providers only (`provider_vetting_state(...).id_verified`). |
| Job fails after the advance went out? | The customer gets back everything Help24 still holds, **fee included**. The advance itself bought the customer's materials and cannot be pulled back; Help24 pursues the fundi if it was misused. Help24 does **not** refund the 40% from its own money. |
| Threshold and share | KES 10,000 and up, 40% rounded down to the shilling (`backend/src/mpesa/advance.ts`). |

## How the money works

The advance is its **own payout**, with its own row in `materials_advances` and its own
M-Pesa conversation ids. A transaction's columns describe exactly one payout (the final
one), and the B2C callback finds a payout by its ConversationID, so the advance cannot
share them.

Every status change is a compare-and-set on that row, so a release, an approval and a
dispute that arrive together cannot all act:

| Actor | Transition | Then |
|---|---|---|
| Customer taps Send | `held -> sending` | B2C for the advance; result: `paid_out`, or back to `held` (or `frozen` if a dispute came meanwhile) |
| Final payout (approval or auto-approval) | `held -> cancelled` | the full amount goes in the final payout |
| Dispute opens | `held -> frozen` | the ruling covers the full amount |

Whoever claims the row first decides. The others see the new status and act on it:

- **Final payout** pays `job - advance` once the advance is `paid_out`, the full job if it
  was cancelled or frozen, and **refuses while it is `sending`** (the event retry comes
  back once M-Pesa answers; after 3 tries it dead-letters and can be replayed).
- **Dispute rulings** work on the held amount: full release = `job - advance`; full refund
  = `total_paid - advance` (the held 60% plus the fee); a split can never exceed what is held.
  No money ruling while an advance is in flight (ESCALATE is still allowed).
- **Reads fail closed.** If the advance cannot be read, money paths refuse instead of
  assuming there is none (assuming would pay the 40% twice). The only exception is a table
  that does not exist yet, which cannot hold an advance.
- **A B2C error that certainly sent nothing** (`B2cNotSentError`) puts the advance back to
  `held` so the customer can retry. **An unknown outcome** (timeout, 5xx) stays `sending`;
  the admin alert "Payout with no M-Pesa result" lists it after 30 minutes.

Not `@Restrict('pay')`: sending money already paid for on this job settles the deal, like
approving, and a restriction must never strand the provider's materials money
(`moderation.contract.spec.ts`).

## Where the code is

| Part | File |
|---|---|
| Table | `supabase/migrations/139_materials_advance.sql` |
| Rules (pure) | `backend/src/mpesa/advance.ts` + `advance.spec.ts` |
| Money moves | `backend/src/mpesa/materials-advance.service.ts` + `.spec.ts` (stateful fake honouring compare-and-set) |
| Checkout, final payout, callbacks | `backend/src/mpesa/mpesa.service.ts` (`initiatePayment`, `releasePayout`, `settleByConversation`, `handleB2cStatusResult`) |
| Routes | `GET /mpesa/materials-advance/:postId?user_id=` (quote), `POST /mpesa/materials-advance/:postId/release` |
| Disputes | `disputes.service.ts` (freeze), `decisions.service.ts` (held math) + `decisions.advance.spec.ts` |
| Lifecycle | `GET /jobs/:postId/lifecycle` returns `materials_advance { status, amount, can_release }`; settlement `amounts.advance_paid` and `amounts.held` |
| Alert | `admin-alerts.service.ts`: stuck advances join `payout_stuck` |
| App | `payment_screen.dart` (switch), `job_lifecycle_screen.dart` (Send button), copy in `utils/payment_copy.dart` (`MaterialsAdvanceCopy`) |

## Turning it on (in this order)

1. ~~Apply migration 139~~ (done 2026-11-11).
2. ~~Deploy the backend~~ (done, `18547e6`).
3. ~~Publish the app~~ (done, Shorebird 1.0.11 Patch 5, phone-verified).
4. Only when real payouts work: `MPESA_ENV=production`, payout destinations on, and at least
   one verified provider. Then set `MATERIALS_ADVANCE_ENABLED=true` on Render.
5. Test on the sandbox first: a KES 10,000 job with a verified test provider, pay with the
   switch on, Send, check the B2C callback moves the row to `paid_out`, approve, and check
   the final payout is KES 6,000.

## Does the one fee cover it?

Yes, on every job the advance is offered for. The customer pays one 5% fee (capped at
KES 1,000); Help24 pays one M-Pesa collection and TWO payouts (the 40% and the 60%). From the
owner's tariff table, with the second payout assumed to cost as much as collection-plus-payout
again (very pessimistic: business B2C is quoted at KES 5 to 13 a payment):

| Job | Fee | Normal cost | Worst case with the advance | Help24 keeps (worst case) |
|---|---|---|---|---|
| 10,000 | 500 | ~104 | ~208 | ~292 |
| 20,000 | 1,000 | ~158 | ~316 | ~684 |
| 50,000 | 1,000 | ~255 | ~510 | ~490 |

Pinned by `advance.spec.ts`. Two caveats: the table stops at KES 50,000, so above that check the
Safaricom tariff on Help24's own shortcode before relying on the cap; and a job refunded after
an advance returns the fee, so Help24 is out the M-Pesa costs (about KES 120 to 280) on that one job.

## Not built yet

Recorded in docs/later-with-traction.md ("Materials Advance: the parts not built yet"): admin
pages showing the advance, a receipt line, a reconcile button for a stuck advance, SMS, a server
record of terms acceptance, and a tool to recover a misused advance.

## Marketing it

A separate, simple promise for big jobs: *"Big job? Your fundi gets materials money when you
say so, and the rest stays protected."* It only applies with verified providers, so it is also
the clearest reason for a fundi to get verified, and to want the job paid through Help24.
