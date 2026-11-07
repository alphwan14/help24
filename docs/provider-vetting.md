# Provider vetting — ID check and Care check

Status: **built, not applied.** Migrations 135–136, backend, admin dashboard
and app are on branch `feat/provider-vetting`. Nothing is live until the
migrations are applied (owner approval — standing rule) and the backend is
deployed.

## Owner decisions (2026-11-07)

1. **Two tiers, keyed to the category of the listing** (`categories.vetting_tier`):
   - **ID check**: national ID / passport / Alien ID (front and back) plus a
     selfie holding it. Categories: **Tutoring, Driver, Security Guard,
     House Cleaning** (house help posts under House Cleaning).
   - **Care check**: the ID check plus a **DCI Certificate of Good Conduct**.
     Categories: **Babysitting, Caregiving**.
   Moving a category between tiers is one row change (`UPDATE categories SET
   vetting_tier = …`), no release.
2. **eCitizen application receipt accepted for 30 days** while the
   certificate is pending, *with limits*:
   - the provider **can** post care offers; they show on the feed labelled
     **"Certificate pending"**, and they can be messaged;
   - the provider **cannot** apply for care requests or jobs, and **cannot be
     hired** (selected) for care work;
   - at 30 days without an approved certificate the offers are **hidden**
     (`archived_by = 'vetting'`) and reopen automatically when the certificate
     is approved.
3. **Listings from before vetting**: offers in a vetted category whose author
   is not verified show **"Not yet verified"** for **14 days** from the moment
   the migration is applied, then are hidden until the author completes the
   check. (Applied to both tiers.)
4. **Optional ID badge for everyone**: any provider may do the ID check;
   approval shows **"ID verified"** on their listings and profile and turns on
   the existing `users.is_verified` ranking signal.

Still the owner's, before going live: confirm Help24's registration with the
Data Protection Commissioner and add the ID / certificate processing to the
privacy policy (help24.co.ke/privacy).

## Where each rule lives

| Rule | Enforced by |
|---|---|
| Offering vetted work needs the tier (receipt OK for care) | `trg_posts_vetting_guard` (posts insert / category or type change / republish) |
| Applying for vetted requests and jobs needs the full tier | `trg_applications_vetting_guard` |
| Being hired for vetted work needs the full tier | `JobsService.selectProvider` → `provider_meets_vetting(…, false)` — fails closed |
| Labels and hide times can only be set by Help24 | the posts trigger overwrites them for clients |
| A hidden listing reopens only when verified | posts trigger refuses the author; `vetting_refresh_author_posts` reopens |
| Expired notice / receipt hides offers | `vetting_sweep()` every 10 min (`VerificationsSweepService`, kill switch `VETTING_SWEEP_ENABLED=false`) |
| Documents deleted 30 days after the decision | same sweep; `files_deleted_at` |
| Members read only their own status, never paths | `my_verification_status()` |
| The public sees outcomes only | `public_profiles.id_verified`, `public_profiles.care_status` |

Messaging is never restricted by vetting. Phase B ("Book me") booking must
call `provider_meets_vetting(provider, tier, false)` before taking payment for
vetted work.

## Admin

Trust & Safety → **Verifications** (`/dashboard/trust-safety/verifications`):
oldest first, flagged after 24 h (the promise made to providers), and a
"verifications waiting" alert in the bell. Any active admin may decide. A Care
check cannot be approved before the provider's ID. Rejections need a reason,
sent to the provider word for word. Signed links to documents last 5 minutes.

## App (target 1.0.10)

- Profile → Business → **Verify your identity**: status of both checks, the
  upload flow (camera or gallery; PDF or photo for eCitizen documents).
- Before posting an offer or applying in a vetted category, a sheet explains
  what is needed and opens the verification screen, instead of a refusal
  after the form.
- Listings show "Care checked" / "ID verified" / "Certificate pending" /
  "Not yet verified"; the detail page explains a pending certificate.
- `verification_approved` / `verification_rejected` notifications open the
  verification screen.

The Dart was written without a Flutter toolchain (the build sandbox could not
reach pub.dev). Run `flutter analyze` and `flutter test` before releasing;
`test/provider_vetting_test.dart` covers the model, labels, status rules and
error copy.

## Deploy order (each step needs the one before)

1. **Migration 135, then 136** — dry-run first per the standing rules.
   135 stamps the 14-day notice on existing unverified care / ID-tier offers
   at apply time.
2. **Backend** (`help24-backend`). Its feed select now asks `public_profiles`
   for `id_verified, care_status`; deploying before 135 would fail feed
   hydration (the app falls back to its direct read, which also asks for them
   from 1.0.10).
3. **Admin dashboard.**
4. **App 1.0.10** (with Shorebird — docs/shorebird.md).

Apps before 1.0.10 keep working: posting or applying in a vetted category is
refused by the database with a generic message, and their feed shows no
labels. Raising `ops.min_version` to 1.0.10 closes that gap.

## Tests

- `supabase/tests/trust-safety/vetting.test.mjs`: 25 tests against the live
  schema replica. Every rule above, applied twice to prove re-runnability.
- `backend/src/verifications/verifications.spec.ts`,
  `backend/src/jobs/select-provider.vetting.spec.ts`.
- Admin e2e: `admin-dashboard/e2e/run.mjs` § provider verifications.
- `mobile-app/test/provider_vetting_test.dart` (not run — see above).
