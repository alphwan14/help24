# Business Promotion — Production Architecture (Phase 1: Featured Listings)

Customer-facing name: **Promote Business** (never "Ads" / "Sponsored Ads").
Philosophy: Help24 sells **visibility, not attention**. Every promoted item is a
genuine marketplace object that already exists in Help24; promotion is one
additional ranking signal, never a quality override, and never an interruption.

## 1. What is promoted

Help24 has no standalone "business" entity — a provider surfaces through their
**offer posts**. Phase 1 therefore promotes **one existing offer post** (the
provider's service listing). The sponsored card **is** a normal `PostCard` with
a subtle `Sponsored` tag — identical layout, real reputation, real distance.

The schema is polymorphic-ready (`promotion_campaigns.subject_type`), so future
products (Business Spotlight, Hiring Campaigns → job posts, Event Promotion)
reuse the same campaign/package/payment/analytics engine with a new
`subject_type`, not a rewrite.

## 2. Data model (migrations 077 + 078)

| Table | Purpose | Access |
|---|---|---|
| `promotion_packages` | Fixed-price package registry (Starter 300/3d, Growth 700/7d, Premium 1500/14d, Enterprise custom). Pricing lives here, never in code. | Public `SELECT` (active only) — same trust model as `categories` |
| `promotion_campaigns` | Campaign lifecycle + purchase-time package snapshot (`package_name`, `price_kes`, `duration_days`, `placements`) | service_role only |
| `promotion_payments` | M-Pesa STK ledger for promotions (platform revenue; **not** `transactions`, which is escrow/B2C-bound) | service_role only |
| `promotion_settings` | Serving/moderation knobs: discover gap + first offset, per-placement slot caps, nearby radius, `auto_approve`, payment TTL | service_role only |
| `promotion_events` | Raw, append-only analytics events (canonical) | service_role only |
| `promotion_daily_stats` | Derived daily rollup, recomputed idempotently via `fn_recompute_promotion_daily_stats` (055 house style), Nairobi day boundaries | service_role only |

Money is **whole KES integers** everywhere (matches Daraja `Amount` and `fee.ts`).

Key integrity rules:
- One in-flight campaign per post (`uq_promotion_campaigns_live_post` partial unique index over `awaiting_payment|pending_review|active|paused`).
- `post_id ON DELETE SET NULL` + `post_title` snapshot: deleting a post never destroys campaign/payment history; serving skips subject-less campaigns.
- `promotion_payments.checkout_request_id` partial-unique: Daraja callback correlation is unambiguous.

## 3. Campaign state machine

```
draft → awaiting_payment → pending_review → active → completed
  draft|awaiting_payment  → expired      (payment window lapsed, TTL in settings)
  pending_review          → rejected     (moderation)
  active                 ⇄ paused        (owner/admin; resume shifts ends_at by pause duration)
  any non-terminal        → cancelled
```

- Payment success moves `awaiting_payment → pending_review` (or straight to
  `active` when `moderation.auto_approve` is on — the future "verified business"
  path needs a settings flip, not code).
- Admin approval activates: `starts_at = now()`, `ends_at = now() + duration_days`.
- **Correct-by-query serving**: the slots query only ever returns
  `status='active' AND now() BETWEEN starts_at AND ends_at AND post_id IS NOT NULL`
  — an overdue sweep can never cause over-serving. A backend interval sweep
  (60s loop, same pattern as `EventProcessorService`) tidies statuses:
  `active` past `ends_at` → `completed`; stale `draft`/`awaiting_payment` → `expired`.

## 4. Service architecture (NestJS `PromotionsModule`)

```
promotions/
  promotions.module.ts
  settings.service.ts        — promotion_settings knobs, merged over code defaults, cached
  packages.service.ts        — package registry reads (DB-backed, cached)
  campaigns.service.ts       — lifecycle commands; delegates transitions to the state machine
  campaign-state.ts          — PURE transition table (unit-tested, no I/O)
  promotion-payments.service.ts — STK initiate + callback settlement (idempotent)
  serving.service.ts         — placement engine I/O: eligibility query + response shaping
  serving-logic.ts           — PURE relevance/ranking/rotation pipeline (unit-tested, no I/O)
  analytics.service.ts       — event ingest (batch) + owner dashboard aggregates
  promotions-sweep.service.ts — 60 s lifecycle sweep (completed/expired tidy-up)
  promotions.controller.ts   — user-facing routes
  promotions-admin.controller.ts — AdminAuthGuard routes (approve/reject/packages/revenue/settings)
```

User routes (follow the existing convention: `user_id` asserted in body/query):
- `GET  /promotions/packages`
- `POST /promotions/campaigns` (create for an owned, open offer post → `awaiting_payment`)
- `GET  /promotions/campaigns?user_id=` / `GET /promotions/campaigns/:id?user_id=`
- `POST /promotions/campaigns/:id/pay` (STK push) · `GET /promotions/campaigns/:id/payment-status`
- `POST /promotions/campaigns/:id/pause|resume|cancel`
- `GET  /promotions/campaigns/:id/analytics?user_id=`
- `GET  /promotions/payments?user_id=` (payment history)
- `GET  /promotions/slots?placement=&category=&q=&lat=&lng=&limit=` (public, serving)
- `POST /promotions/events` (batched impressions/clicks/taps)

Admin routes (Bearer `AdminAuthGuard`, mirroring disputes):
- `GET /admin/promotions/campaigns?status=` · `GET /admin/promotions/campaigns/:id`
- `POST /admin/promotions/campaigns/:id/approve|reject|pause|resume|cancel`
- `GET/PATCH /admin/promotions/packages` · `GET /admin/promotions/revenue`

Events: new `promotion.*` types in `event.types.ts` flow through the existing
`system_events` outbox + `EventProcessorService` for notifications/retries.

## 5. Payment flow (M-Pesa STK, reusing `DarajaService`)

```
Choose package → POST /promotions/campaigns → POST /promotions/campaigns/:id/pay
  → DarajaService.stkPush (generalized additively: optional accountReference/
    description params; default behaviour unchanged for escrow)
  → same MPESA_CALLBACK_URL → POST /mpesa/stk-callback
  → controller correlates checkout_request_id: transactions first (escrow),
    then promotion_payments (promotion) — zero Daraja config changes
  → paid: campaign → pending_review (or active if auto_approve)
  → app polls GET /promotions/campaigns/:id/payment-status (PaymentScreen pattern)
```

No fee tiers apply — the package price **is** the platform's revenue. No escrow
row, no B2C payout. Settlement is idempotent: a replayed callback on a
non-pending payment is a no-op (mirrors `settleByTransaction` discipline).

## 6. Placement engine (serving)

`GET /promotions/slots` is called by the app **non-blocking, in parallel** with
its organic Supabase feed read; organic content never waits on promotions
(Render cold start ⇒ feed simply renders unsponsored).

Pipeline: **eligibility → relevance → ranking → rotation → cap**
1. Eligibility: `active`, inside window, subject post exists and is `open`/unarchived.
2. Relevance (never bypassed):
   - `category` placement/filter → post category must match.
   - `search` → query must match post title/description/category.
   - `lat/lng` present → distance ≤ `nearby_max_radius_km` (promotion never
     overrides geographic relevance).
3. Ranking: composite of bayesian rating, completion rate (from
   `provider_reputation`), and proximity — promotion buys entry into the slot
   auction among *eligible* campaigns, quality still orders them.
4. Rotation: seeded shuffle among top candidates so equal payers share exposure.
5. Cap: per-placement `*_max_slots` from settings (search/category 1–3 at top;
   discover interleaved).

Response items carry the **same post JSON shape as the app's feed rows** plus
`campaign_id` + `placement`, so the client renders a real `PostCard`.

## 7. Client composition (Flutter)

- `PromotionService` (http, `JobsService` pattern) — slots, campaigns, pay, analytics, event batch.
- `FeedComposer` — pure Dart, unit-tested: interleaves sponsored items into the
  organic list per settings (`first_after`, `gap`, `max_slots`), never clusters,
  never displaces the organic order. Widgets stay dumb ("no Sponsored logic in
  feed widgets").
- `PostCard(sponsored: true)` — adds a small `Sponsored` tag + faint accent
  border. Nothing flashy; identical card otherwise.
- Placement mapping in `DiscoverScreen`: search query active → `search`;
  category filter active → `category`; otherwise `discover`; lat/lng always
  passed when known (`nearby` relevance).
- Profile → **Promote Business** section: Campaigns list, Create flow
  (pick owned offer post → package → review → STK pay with `PaymentScreen`-style
  polling), per-campaign Analytics, Payment History.
- Impressions/clicks batched to `POST /promotions/events` (fire-and-forget, deduped per campaign+placement per feed load).

## 8. Admin dashboard (Next.js)

New sidebar section **Promotion**: Campaigns (all/pending/active — DataTable,
payments-page pattern), campaign detail with Approve/Reject server actions
(disputes pattern via `lib/api.ts` `adminRequest`), Packages editor, Revenue
summary. Approval writes go through the backend admin routes — never direct DB.

## 9. Security model

- All promotion tables **born locked** (060 pattern): RLS pinned `TO service_role`;
  the only public surface is `promotion_packages` (active rows, pricing only).
- No dependency on the S1 client-JWT bridge: clients reach promotion data only
  through backend endpoints.
- Campaign creation verifies post ownership (`posts.author_user_id` must equal
  the asserted `user_id`) and subject type (`offer`, open, not archived).
- User-facing routes follow the existing asserted-`user_id` convention (same as
  jobs/mpesa/reviews today); when the platform-wide Firebase-token hardening
  lands, promotion routes adopt the same guard in one place (controller).
- Admin mutations require `AdminAuthGuard` roles (approve/reject: senior_admin+).

## 10. Verification gates (per milestone)

1. **DB**: migrations 077/078 reviewed + applied in Supabase SQL editor (additive only).
2. **Engine**: `npm test` — state-machine, serving, payments-settlement, analytics specs.
3. **Payment**: sandbox STK + `MPESA_DEV_FORCE_SUCCESS` simulated callback path.
4. **App**: `flutter analyze` + composer unit tests + manual feed/checkout pass.
5. **Admin**: `next build` + manual approve/reject pass.
