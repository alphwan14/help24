# Provider vetting — ID check and Care check

Status: **migrations 135–137 applied to production 2026-11-07** (owner
approval in chat, same day). See § Rollout log. Backend, dashboard and app
follow in the deploy order below.

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

## Rollout log

Owner approval: applying 135, 136 and 137 to production, given in chat on
2026-11-07. All SQL went through `supabase db query --remote` (linked project
`taohzhnvaitrpxcyjflq`), and every read used `--read-only`.

### Before (2026-11-07 ~14:00 UTC)

Pre-flight on branch `feat/provider-vetting` (`a2e1d46`):

- backend: `tsc` clean, jest 878 passed; boot check `153 routes … undeclared=0 (mode=enforce)`
- DB replica: trust-safety 80/80, vetting 25/25, site-events 4/4
- admin: 155 unit, e2e 137/137. help24_website: 94/94
- app: `flutter analyze` 0 errors, with no issues in branch code after `a2e1d46`.
  `flutter test` (WSL): 1609 passed, 3 known environmental failures

HANDOFF §1 fingerprints:

| | HANDOFF | 2026-11-07 |
|---|---|---|
| escrow rows / sum | 17 / 73,250 | 17 / 73,250 |
| transactions rows | 45 | 45 (sum 136,375) |
| app_settings / feed_settings rows | 6 / 13 | 6 / 13 |
| dead-lettered `payment.success` | 1 | 1 |
| escrow md5 (`docs/sql/trust-safety-fingerprints.sql`) | `ec96a938…` (2026-09-27) | `77a7509e…` |
| transactions md5 | `5d2651c6…` (2026-09-27) | `99b22200…` |
| `/config` ETag | `W/"3b6c0888a44bf4c1"` | `W/"34a90feef291bf06"` |

The hash drift has a known cause. The 2026-10-29 pre-launch audit opened a
sandbox dispute, `escrow.disputed` and `dispute.opened` at 17:20 UTC, and left
it open for the owner (`prelaunch-audit-2026-10-29.md`, row "Dispute"). That
moved one escrow row and one transaction to `disputed`. Counts and sums are
unchanged, there have been no settlements or finance actions since
2026-09-27, and no migration since then alters either table. The ETag moved
with the App controls edits of 2026-10-26. HANDOFF's `351c0047…` came from an
older recipe and cannot be compared. **New money baseline:
`77a7509e…` / `99b22200…`.** It was identical after every step below.

Each dry run is one `DO` block that `EXECUTE`s the whole file, reports, and
then `RAISE EXCEPTION`s, so rollback is guaranteed by construction (HANDOFF §0
rule 4). After each one, a read confirmed that nothing was left behind.

| # | Step | Evidence |
|---|---|---|
| 1 | Dry run 135 | `HELP24_DRY_RUN_OK`. Tiers `babysitting=care, caregiving=care, driver=id, house-cleaning=id, security-guard=id, tutoring=id`. **2 existing offers get the 14-day `not_verified` label** (Babysitting 1, Caregiving 1; 2 authors), out of 2 open offers in vetted categories. No other post column changed and nothing was archived. `public_profiles` gains `id_verified, care_status` after the existing 10 columns. Money unchanged. Afterwards: no `vetting_tier` column, no table, `public_profiles` still 10 columns |
| 2 | Apply 135 | 14:04:16 UTC, one transaction |
| 3 | Verify 135 | Tiers exactly as in the dry run. `public_profiles` = `…,is_online,id_verified,care_status`, still granted to anon. The two offers are labelled with `vetting_hide_at` **2026-11-21 14:04:22 UTC**. `trg_posts_vetting_guard` and `trg_applications_vetting_guard` are enabled (`O`). `provider_verifications` has RLS on and no SELECT for anon or authenticated. Nothing is `archived_by = 'vetting'`. Money unchanged |
| 4 | Dry run 136 | `HELP24_DRY_RUN_OK`. Bucket private, 8 MB, jpeg/png/webp/pdf; one policy `provider_verifications_insert_own:INSERT`. Afterwards: no bucket, no policy |
| 5 | Apply 136 | 14:05:33 UTC |
| 6 | Verify 136 | `storage.buckets` `provider-verifications` has `public = false`, 8,388,608 bytes, the four MIME types. The only policy is INSERT for `authenticated`. Public URL `/object/public/provider-verifications/…` → 400 |
| 7 | Dry run 137 | `HELP24_DRY_RUN_OK`. `site_events` with RLS on; anon has no SELECT or INSERT; functions `record_site_event`, `admin_provider_card_stats`. Afterwards: nothing left |
| 8 | Apply 137 | 14:06:15 UTC |
| 9 | Verify 137 | RLS on. `has_table_privilege` anon SELECT/INSERT false, authenticated SELECT false. anon may EXECUTE `record_site_event` and may not EXECUTE `admin_provider_card_stats`. 0 rows. From outside with the anon key: `GET /rest/v1/site_events` → 401 `42501 permission denied`, `rpc/admin_provider_card_stats` → 401, `GET /rest/v1/provider_verifications` → 401 |

### App on a phone, before the backend deploy

These checks used release-signed test builds of the branch (WSL `build-release.sh`,
cert `48f1d72b…`, versioned 1.0.9+10, not published), installed with
`adb install -r` over v1.0.9 on the S20+ (`R5CN218ZKZY`, alphwan14).

| Check | Result |
|---|---|
| Install over 1.0.9 | Kept the session (`[AUTH][BRIDGE] ok=true`), no crash, Discover loads |
| Discover | Neema's Babysitting offer shows "Not yet verified", against the old backend too |
| Profile → Verify your identity | Opens and reads "Not started" from `my_verification_status()`. ID check → National ID selects (RadioGroup) and shows the instructions. **No documents were uploaded**: that would put real ID images in production |
| Offer → Babysitting, first build `0ea12f3` | **Defect:** no sheet. The provider went straight into the form, and the gate fired only at submit, after every step |
| Same, after the fix (`441f77b`) | "Care check needed" sheet as soon as Babysitting is picked. "Not now" stays on the category list, "Verify now" opens the screen with the Care check first, and Plumbing goes straight to the form |
| Listing detail | "Not yet verified" chip plus "This provider has not verified their identity yet." |

The owner also asked for plainer copy, with no dashes, on the new pages. App
(`441f77b`) and admin (`409fa88`) copy were rewritten. The database's own
submission messages from 135 still contain dashes, and the app shows them as two
sentences.

### Backend, dashboard, website (2026-11-07)

| # | Step | Evidence |
|---|---|---|
| 10 | Merge `main` into the branch | `ba1a90e` (admin Google sign-in, from a parallel session) merged cleanly. Admin unit 155/155. e2e: one run aborted in App controls (timeout, unrelated), and the re-run passed 144/144 |
| 11 | Merge PR #3 | `abb66a5`. Render `dep-dbnm7lqvcj2c738iu7t0` live at 17:47:08 UTC (69 s). Rollback target: `dep-dblorlfb9u1s73dkl7b0` (`9418f8e`) |
| 12 | Verify backend | `/health` 200 (`degraded` = Redis, as before). `/admin/verifications` 401 with no token and with a forged token, 404 before the deploy. `/feed?page=1&page_size=3` 200, carrying `vetting_label`/`vetting_hide_at` and `users.id_verified`/`care_status`; Silas's Caregiving offer reads `not_verified`, hidden at 2026-11-21 14:04:22 UTC. `/promotions/campaigns` 401. Logs: `[VETTING] sweep started — interval=10m`, `153 routes … undeclared=0 (mode=enforce)`, moderation and admin self-checks ✓, **no error-level lines** |
| 13 | Website | help24_website PR #1 merged (`1e58521`), Vercel deploy success, `POST /api/e` 404 → 204. One headless-Edge open of `help24.co.ke/p/k4DZSM…` (the owner's own card) wrote `site_events` row 1: `provider_card_open`, source `link`, desktop, edge, app_version 1.0.9, path without the query string |

The admin dashboard does not auto-deploy (`vercel --prod` from
`admin-dashboard/`). The Verifications and Provider cards pages appear there
only after that deploy.

Not related to this deploy: `/feed?page=1` returns fewer items as `page_size`
grows (20 → 20, 30 → 11, 40 → 1, 50 → 0, of 41 candidates). The deploy changed
only two select columns. The app pages at 20.
