# Provider card — "Find me on Help24"

Status: **Phase A built (2026-11-04), not released. Phase B blocked.**

## What it is

A provider's digital business card: name, photo, profession, their Help24
record and a QR code. Providers hand it to the customers they already have —
the ones met at independent gigs — so those customers find them on Help24.
Every provider becomes a marketer for the platform, and every customer they
bring arrives already wanting a specific person, which is the one kind of
demand an early marketplace with thin supply can actually serve
(see `direct-service-requests-assessment.md` §2).

The pitch the card carries is a professional's, not a plea: "I take bookings
through Help24", the way "I have a Till number" signals a serious business.
It never says "so I don't get conned by you" — that reads as distrust of the
customer it is handed to.

## Phase A — built, no money claim

| Piece | Where |
|---|---|
| Profile → Business → **My Help24 card** (behind the provider-readiness sheet) | `mobile-app/lib/screens/profile_screen.dart` |
| The card, QR, **Share card** (PNG + link through the share sheet), **Copy link** | `mobile-app/lib/screens/provider/provider_card_screen.dart` |
| Link format and parsing: `https://help24.co.ke/p/<uid>`, `?src=qr` for the QR | `mobile-app/lib/services/provider_card_link.dart` |
| One owner for the links channel (agent links + card links) | `mobile-app/lib/services/app_links.dart` |
| App Link `/p/` path, image share over `com.help24.help24/share` | `AndroidManifest.xml`, `MainActivity.kt`, `res/xml/chat_document_paths.xml` |
| Web copy of the card for people without the app | `help24_website/app/p/[id]/page.tsx`, `lib/provider-card.ts` |

Decisions worth not re-litigating:

- **The id is the Firebase UID.** `public_profiles` is already anon-readable by
  it, so the link exposes nothing new. No schema change, no migration. A short
  vanity code can come later if providers ask for one to print.
- **Nothing on the card mentions payment.** Tests on both sides fail if the
  card says pay / protect / escrow / secure / guarantee / safe.
- **The record line is the public profile's**, word for word on app and web:
  `★ 4.8 (12) · 9 jobs done on Help24`, `New on Help24`, or nothing when the
  record could not be read. Never a zero-filled report card.
- **The web page is `noindex`** and 404s for any member without a name and a
  confirmed profession, so a customer's id never produces a page about them.
  It does not check `has_phone`: the app counts the sign-in phone as on file,
  which the view cannot see.
- **The card is always light**, whatever the app theme — it is read on other
  people's screens and on paper.
- **A card link opens the profile after the launch hold**, for guests too.

Owed before release: device check (share to WhatsApp, scan the QR with the
camera, App Link opens the profile on a cold start and a warm one), then ship
in ≥ 1.0.9. The website half deploys on push and is harmless before the app
ships: 1.0.8 does not claim `/p/` links, so they open in the browser.

What Phase A measures: `provider_card_open` (source qr|link) on the website.
If providers do not share the card, Phase B is not worth building.

## Phase B — "Book me on Help24", blocked

Card copy becomes: **"Book [Name] on Help24 · Your payment is held safely
until the job is done."** Never "guaranteed", "100% safe" or "insured".

Blocked until all of these are true — the promise is false before them:

1. `MPESA_ENV=production` (it is `sandbox`; last transaction 2026-08-01).
2. Providers can actually be paid: `PAYOUT_DESTINATIONS_ENABLED` on, Africa's
   Talking SMS wired, the six stuck escrow rows (D22) resolved.
3. A Play Store listing. A stranger's QR that ends in "allow installs from
   unknown sources" is the exact gesture anti-scam advice says never to make.
4. Someone owns dispute rulings with a response time.
5. A legal read on holding customer funds (National Payment System Act / CBK).

### Owner decisions, 2026-11-04

- **Tariff: 5% of the job, paid by the customer, minimum KES 30, maximum
  KES 1,000.** The provider keeps 100% of the agreed price. Replaces the flat
  tiers (20/45/95/195/295), which cost more in M-Pesa fees than they earned on
  mid-size jobs. Shown, never hidden, and named for what it buys:
  "Total KES 1,050 · includes KES 50 payment protection" — not a
  "convenience fee".
- **The fee comes back on a refund.** Already true for a FULL_REFUND:
  `clientRefundFor` returns `total_paid`, which is amount + fee
  (`backend/src/admin/disputes/decisions.service.ts`). A PARTIAL_SPLIT is capped
  at the escrowed job amount, so the fee stays with Help24 there — part of the
  job happened and the hold and the ruling were both delivered.
- **Customers a provider brings get the fee waived, bounded:** one waived job
  per customer, ever — the first job with the provider whose card brought them,
  and only when that card is how they joined Help24 (attribution captured
  before sign-up, like agent codes). At most 10 waived jobs per provider per
  month. Help24 still pays M-Pesa in and out on those jobs, so the waiver is an
  acquisition cost of roughly KES 23–255 per new customer. Unbounded, it would
  lose money on every card job forever and make fake reputation jobs free.
- **No reward for sign-ups.** The booking is the reward. Paying per sign-up
  invites fake accounts.

### Building it

Phase B needs a backend change — the tariff and the waiver in
`backend/src/mpesa/fee.ts`, plus card attribution — allowed under the freeze as
a business requirement. The fee is computed in TWO places that must agree,
`fee.ts` (charged) and `mobile-app/lib/utils/payment_utils.dart` (displayed).
The new tariff therefore ships as ONE step: the app version that displays it,
the backend that charges it, and an `ops.min_version` raise to that version, so
no phone shows a total that the M-Pesa prompt then contradicts. Not before
`MPESA_ENV=production` — until then it moves only sandbox money. Before
building, check the M-Pesa cost per job against the Safaricom tariff on Help24's
own shortcode (Paybill and Till are charged differently), and ask an accountant
about VAT on the fee (16% if Help24 is registered).
