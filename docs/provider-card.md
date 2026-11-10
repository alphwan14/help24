# Provider card — "Find me on Help24"

Status: **Phase A live in v1.0.9 (2026-11-04). Phase B ("Book me", payment
protected) designed, decided, not built — the NEXT PRIORITY once M-Pesa is in
production and the blockers below are lifted (owner, 2026-11-07).**

## Where we stopped (2026-11-06)

Read this first when picking the work up.

**Live:** the card in the app (v1.0.9, published and checked on the owner's
S20+ from the release APK) and `help24.co.ke/p/<uid>` on the website.

**Measuring card use (built 2026-11-07, owner chose first-party).** The
website beacons its events to its own `/api/e`, which writes them to Help24's
database through `record_site_event()` (migration 137): no cookies, no IP, no
device id, nothing third-party. Admin dashboard → Partners → **Provider cards**
shows opens (QR vs link), how many providers' cards were opened, "Open in
Help24" taps, and the providers whose card is used most. Goes live when
migration 137 is applied and the website is deployed. Still not counted:
*members who joined through a card*. That needs card attribution stored at
sign-up, which Phase B's waiver needs anyway.

**Phase B blockers, as last checked:**

| # | Blocker | State | Last checked |
|---|---|---|---|
| 1 | `MPESA_ENV=production` | **sandbox** | 2026-10-30 (`/mpesa/health`, now admin-only) |
| 2 | Providers can be paid: `PAYOUT_DESTINATIONS_ENABLED`, SMS, the six stuck escrow rows | flag **off**, Africa's Talking **not wired** | 2026-11-04 |
| 3 | Play Store listing | **none**; the app ships as an APK from help24.co.ke | 2026-11-06 |
| 4 | Someone owns dispute rulings, with a response time | **not decided** | — |
| 5 | Legal read on holding customer funds (NPS Act / CBK) | **not done** | — |

**Already in place that Phase B relies on** (built since this doc was first
written):

- **Auto-approval, live 2026-11-04** (migration 134, backend `9418f8e`): a job
  the client never answers approves itself after 48 h, with reminders at 24 h
  and 44 h; a dispute at any point stops it. A provider who did the work is no
  longer waiting on the client forever, which is half of what "Book me" offers.
  The approve-screen line ("approves automatically …") waits for app ≥ 1.0.10
  (`docs/next-app-release.md`).
- **Payout race fixed** in the same change: the payout claims the payment
  before calling M-Pesa, and a dispute freezes only money that has not started
  paying out.
- **Refund returns the fee** on a FULL_REFUND (owner decision below; already
  true in code).

**Next steps, in order:**

1. Owner: choose how card use is measured (above), so Phase A can be judged.
2. Owner: the blockers that are not code — #3 Play listing, #4 dispute owner
   and response time, #5 legal read, the Safaricom tariff on Help24's own
   shortcode, VAT on the fee (accountant).
3. Code, once blockers 1 (M-Pesa production) and 2 (providers can be paid)
   are cleared: the tariff and waiver as one
   release (see "Building it" below) — `fee.ts`, `payment_utils.dart`, card
   attribution at sign-up, the waiver limits, then `ops.min_version` raised to
   that app version.
4. Only then change the card copy to the Phase B line.

**Related thread — vetting providers for sensitive work: BUILT 2026-11-07,
not yet applied — see [`provider-vetting.md`](provider-vetting.md).** The
owner accepted the two tiers, the eCitizen receipt for 30 days (listed and
messageable, labelled "Certificate pending", but not able to apply or be
hired until the certificate is in), 14 days' notice for existing listings,
and the optional ID badge for every provider. The proposal as written on
2026-11-04: Booking a stranger safely
matters most for care work, so it belongs next to Phase B:

- **ID check** (national ID / passport / alien ID, front and back, plus a selfie
  holding it) for tutors, drivers, house help, security guards.
- **Care check** (the ID check plus a DCI Certificate of Good Conduct) for
  babysitting, nanny, day care, elderly and special-needs care, caregiving,
  maternity and night nursing.
- Keyed to the **category of work being offered or applied for**, not the
  profession picked at sign-up (the one live Babysitting offer is by a lash
  technician). Enforced in the database, because posts and applications are
  written straight to it. Reviewed by an admin within 24 h; clients see only
  "ID verified" / "Care checked"; images deleted 30 days after the decision
  (Data Protection Act 2019). Approval switches on the existing, never-used
  `verified` flag (which already shows a badge and boosts ranking).
- **Four owner decisions before building:** (1) accept the two-tier category
  list or move some (e.g. tutors into the Care check); (2) accept the eCitizen
  application receipt for 30 days while the certificate is pending, or require
  the certificate; (3) give the two existing Babysitting/Caregiving offers 14
  days with a "Not yet verified" label, or hide them at launch; (4) offer the
  ID badge optionally to every other provider (recommended: yes).
- Also owner: confirm Help24's registration with the Data Protection
  Commissioner and update the privacy policy before it goes live.
- Shape: one migration (verifications table, per-category requirement, the
  database check), a private storage bucket, an upload step in provider
  onboarding, a review queue in the admin dashboard. App part targeted for
  1.0.10, with the auto-approval line.

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

Shipped in 1.0.9 (2026-11-04) after a device check on the release APK: the
card renders, the QR decodes from a screenshot to the right link, the share
sheet carries the PNG, a card link opens the profile from a warm and a cold
start, agent links still route, Copy link works. The website half deploys on
push; phones on 1.0.8 open `/p/` links in the browser.

What Phase A measures: `provider_card_open` (source qr|link) on the website —
**but nothing collects it yet** (see "Where we stopped"). If providers do not
share the card, Phase B is not worth building.

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
  KES 1,000.** Reconfirmed 2026-11-10 and shipped (`fee.ts`,
  `payment_utils.dart`, one golden table in both test suites). The KES 30 minimum
  exists because M-Pesa in and out costs about KES 23 on any job up to
  KES 1,000, and 5% alone loses money below about KES 460. The cap stays
  because big jobs are where cash is most tempting: KES 1,000 on a KES 50,000
  job (2%) reads as cheap protection, KES 2,500 reads as worth dodging, and the
  capped fee still clears about KES 745 after M-Pesa. The provider keeps 100% of
  the agreed price. Replaces the flat
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
