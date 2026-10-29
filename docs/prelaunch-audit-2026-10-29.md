# Help24 pre-launch audit — 2026-10-29

Evidence-based audit of the live product: two physical phones, the production
backend and database (read-only except where approved), the admin dashboard's
test harness and production access controls. Branch `audit/prelaunch-2026-10-29`
from `main` at `7e6df8c`.

## A. Executive summary

**Verdict: restricted launch only after two actions — apply migrations 129 and
130 (paste into the Supabase SQL editor), then the post-apply checks in §J.**
Until 129 is applied, anyone holding the app's public key can read every
member's notifications, including the text of private chat messages.

- Scenarios exercised: 15 (§B) — 11 pass, 2 pass with a defect found, 1 fail
  then fixed, 1 blocked (the payment tap, refused by the session's permission
  policy).
- Defects found: 20. Fixed in production: 1 (D2, backend auth). Fixed in code
  and verified on a phone: 4 (D3, D6, D7, D14). Fixed in code with tests, not
  deployed: 2 (D8, D9 dashboard). Migrations written, not applied: 129, 130,
  131 (D1, D4, D5, D9). Open with a recommendation: 10.
- Production changes made (each approved in chat): Render
  `AUTH_ENFORCE_ONLY` emptied (backend auth now fully enforced); test records
  between the owner's two accounts (cleaned up, §J). No migration was
  applied — the tool refused `apply_migration`.

## B. Coverage matrix

| # | Journey / scenario | Env | Expected | Observed | Result | Evidence |
|---|---|---|---|---|---|---|
| 1 | Update 1.0.4 → 1.0.8 in place | A21s | session + local chats survive | same 10 conversations, previews, unread 3; soft-update banner gone | Pass | shots a21_pre_messages / a21_post_messages |
| 2 | Cold start | S20+, A21s | splash → ranked feed, no 401 | first frame 389 / 1484 ms; feed ready +1735 / +1751 ms; token exchange before install | Pass | `[LAUNCH]` traces |
| 3 | Offline cold start | S20+ | cached feed, honest banner | deadline handover 3.0 s, "No internet connection", notifications keep cache | Pass | `[LAUNCH] +3001ms handing over (deadline)` |
| 4 | Create Request (custom category, budget, photo, description) | A21s | validation, accurate preview, one row | empty/whitespace title and KES 0 refused; preview exact; double-tap → 1 row; DB fields match | Pass | post f1de6413 |
| 5 | Discover + search from other account | S20+ | finds it, role-correct action | "audit" → 1 result, 1.26 s; Offer Service (owner sees Manage) | Pass | `[FEED][REQ 5]` |
| 6 | Offer → notification → applicants → chat | both | 1 application, push, deep link | 1 row despite double tap; push 1.1 s; tap → Applications for this post; Message → post-scoped chat | Pass with defect D6 | |
| 7 | Text, document, place; push deep links (bg) | both | delivered, receipts, exact destination | text push 2.4 s; PDF byte-exact (md5 match), private ref; place coordinates 0 m from the fused fix (45 s old); taps open chat d5dc71f3 on both phones | Pass | |
| 8 | Photo in chat | S20+ → A21s | delivered | **415 CONTENT_MISMATCH**, honest "Not sent"; after fix D3 the queued photo auto-retried and delivered | Fail → fixed | message 0a408612 |
| 9 | Offline queue: text + PDF, force-stop, reconnect | S20+ | durable, exactly once | "Waiting to send", survived force-stop, drained on reconnect, 1 row each | Pass | |
| 10 | Accept offer / select provider | A21s | assigned, provider notified, no money | status assigned, W selected, 1 provider_selected push, 0 transactions, 0 escrow | Pass | |
| 11 | Pay (Secure Service) | A21s | kill switch refuses | not tapped — the session's permission policy refused a "real-world transaction"; verified by code + live config only | Blocked | payment_screen.dart:149, /config |
| 12 | Profile bio: cancel, save, restore | S20+ | cancel writes nothing; save persists only that field | as expected | Pass | users row |
| 13 | Delete for everyone | S20+ → A21s | tombstone everywhere | bubble tombstone on both; **list preview kept the text** (D7, fixed in code) | Pass with defect | |
| 14 | Admin access control (prod) | curl | 401 / login redirect | every admin route 401 with none/forged token; pages 307 → /login | Pass | §E |
| 15 | Admin e2e (fake stack) | local | — | 115/115 | Pass | `npm run test:e2e` |

Not tested (and why): sign-out / account switch on the phones (would risk the
owner's sessions); device restart; live-location "On my way" journey; dispute
creation; T&S report from the app (would create a real moderation item);
dashboard UI against production (needs an admin session); M-Pesa sandbox STK
(refused, see #11); iOS.

## C. Defect register

Severity: P0 critical · P1 launch blocker · P2 high · P3 polish.

| ID | Sev | Defect | Root cause | Status |
|---|---|---|---|---|
| D1 | **P0** | Anyone with the public key reads all 320 notifications (189 quote private chat text) and can rewrite them | 041's `notifications_anon_read/update` (USING true) + anon grants | **Migration 129 written + tested, not applied** |
| D2 | **P0** | No-token callers act as any member on every backend route except /promotions (proved: any member's job history) | `AUTH_ENFORCE_ONLY=/PROMOTIONS` left from Stage 1 | **Fixed** (env, approved); verified 401 + both phones fine |
| D3 | P1 | Ordinary PNG photos can never be sent in chat (415) | image_picker writes JPEG bytes under the original `.png` name; client typed uploads by extension | **Fixed** (`contentTypeForBytes`), tests red→green, device-verified |
| D4 | P1 | Provider phone numbers anon-readable (`providers`) | Studio default policies (known since 08-06) | 129 |
| D5 | P1 | Posts / applications / image rows insertable in anyone's name; any image row deletable by anyone; any avatar overwritable | WITH CHECK true / USING true; storage `profiles_update` for anon | 129 + 130 |
| D6 | P2 | Chat bar says "X offered KES <budget>" for an offer that named no price ("KES 0" on open requests) | fallback to post price | **Fixed**, test red→green, device-verified |
| D7 | P2 | A message deleted for everyone keeps showing its text in both conversation lists | `chats.last_message` never retired | **Fixed in code** (device check §J) |
| D8 | P2 | Overview money 100× too small (locked escrow KES 68,700 shown as "KES 687") on Overview, Revenue, Refunds, Trends | local `n / 100` formatters (same bug Payments had) | **Fixed** + guard test |
| D9 | P2 | Overview "Active Jobs" 19 (true 10), "Completed Jobs" 1 (true 9), "Total Revenue" = gross over latest 200 tx | wrong definitions in `admin_overview` | Page fixed; **migration 131 written, not applied** |
| D10 | P2 | Payments kill switch enforced only in the app | backend M-Pesa routes never read `ops.kill_switches` | Open — must be server-side before Daraja production |
| D11 | P2 | Author can hard-delete a post over REST, cascading its disputes/reviews/completions | `posts_delete_owner` policy; the app itself only archives | Open — drop the policy (needs approval); dead `PostService.deletePost` |
| D12 | P2 | "Delete for everyone" keeps the text server-side (and in the chat notification row) | soft flag only | Open — product decision (evidence retention vs. privacy) |
| D13 | P2 | Persisted live journey is not account-scoped and survives sign-out; resumes before auth (token-less /routes/compute for 3 days) | JourneyEngine not registered with SessionScope | Open |
| D14 | P3 | Back / Save / Delete on the post screen and the photo composer's Send have no screen-reader name | icon-only buttons | **Fixed** (required label) |
| D15 | P3 | Conversation list calls a queued message "Not sent" (same word as a failure) | list label | Open |
| D16 | P3 | Accept (select provider) and Delete for everyone have no confirmation | — | Open (recommendation) |
| D17 | P3 | Release build logs every post on each feed fetch (`📦 Post:`) | leftover debugPrint | Open |
| D18 | P3 | `seen_at` can precede `delivered_at` | realtime seen beats background ack | Open |
| D19 | P3 | `next lint` has no ESLint config — the dashboard has no lint gate | — | Open |
| D20 | P2 | "Delete post?" promises the post "and its images" are permanently deleted; the post is archived and its photo stays publicly served (HTTP 200 after delete) | delete is a soft archive (correct for disputes/reviews); copy and storage were never aligned | Open — reword the dialog, and remove or privatise the photos of archived posts |

## D. Physical-device verification

- Galaxy S20+ (SM-G986U, Android 13) — account W; Galaxy A21s (SM-A217F,
  Android 12, wireless adb) — account L. Both are the owner's accounts.
- Builds: published 1.0.8 (sha256 6e517376…2568) on both, then three
  arm64-only test builds of the working tree (Windows, release key; test use
  only, never publish).

## E. Admin dashboard

- Production: 11 admin API routes refuse missing and forged tokens (401); write
  routes (config PATCH, feed DELETE, notify-providers) 401; dashboard and
  partner pages redirect to /login without a session.
- Harness: e2e 115/115, unit 153/153 (incl. new money-units guard), tsc clean.
- Not verified: the UI against production data (no admin session in this
  audit) — the metric findings come from reading the code and recomputing each
  card against the database.

## F. Performance (measured, production)

| Metric | S20+ | A21s |
|---|---|---|
| Android first frame (am start TotalTime) | 362–462 ms | 986–1484 ms |
| Launch → ranked feed installed | 1.73–1.80 s | 1.75–2.13 s |
| Offline launch → cached feed | 3.0 s (deadline) | — |
| Discover search round trip | 1.26 s | — |
| Request create → card on screen | — | ~1.6 s incl. photo upload (0.7 s) |
| Chat text → push on other phone | 2.4 s | — |
| Offer → owner push | — | 1.1 s |

The network round trip (Kenya → Render Frankfurt / Supabase Dublin) dominates;
device speed barely changes the feed time. No targets existed; recommend
p50 ≤ 2 s launch-to-feed on the A21s class as the bar.

## G. Security and data integrity

D1, D2, D4, D5, D10–D13 above. Also from the Supabase advisor (unchanged):
3 SECURITY DEFINER views (`debug_auth_status` is debug-only — drop it),
`mark_messages_read(chat_id)` is callable by any signed-in user for any chat
(needs a participant check), leaked-password protection off, 14 functions with
mutable search_path, `pg_trgm` in public. `/mpesa/health` is public and echoes
the shortcode and a partly masked consumer key.

## H. Codebase cleanup

Removed nothing speculative. Identified dead code with zero callers:
`PostService.deletePost`, `ApplicationService.deleteApplication`,
`ApplicationService.getApplicationCount`, the legacy `messages` /
`conversations` tables (0 / 1 rows). Retained on purpose: migrations (applied
history), the overview's 12-query fallback (now the corrected path until 131).

## I. Recommendations

Launch necessities: apply 129/130 (+131); enforce the payments kill switch on
the backend before `MPESA_ENV=production`; drop `posts_delete_owner`; narrow
`applications` SELECT once cards read the applicant count elsewhere.
High value: confirmations on Accept and Delete-for-everyone; account-scope the
journey engine; decide retention for deleted messages; a dashboard sandbox
badge driven by `MPESA_PRODUCTION_SINCE`.

## J. Release gate

**Tested:** §B. **Passed:** everything in §B except #8 (fixed), #11 (blocked).
**Failed and still failing in production:** D1, D4, D5 until 129/130 run;
D8/D9 until the dashboard is redeployed (and 131 runs).

**Pre-existing failures (not regressions):** Flutter 3 environmental
(design_tokens_export ×2, trust_safety_test load — sibling repos absent in the
WSL mirror); `chat_store_test` "a later sync whose profile read FAILED keeps
every name" failed once in the baseline and passed in the rerun (flaky).
Suites after the fixes: Flutter 1575 pass / 3 env; backend 818 pass (no
backend code changed); dashboard unit 153/153, tsc clean, e2e 115/115; DB
T&S 80/80, anon-access 14/14.

**Production modified:** Render env `AUTH_ENFORCE_ONLY` (empty). Test data:
request f1de6413 (now archived/cancelled), 1 application, 8 chat messages (3
attachments, 2 deleted for everyone) in chat d5dc71f3 (both accounts are the
owner's), their notifications; bio edited and restored exactly. Phones left on published
1.0.8; pushed test media removed.

**Committed** on `audit/prelaunch-2026-10-29` (not pushed, nothing deployed or
released). **Before launch, in order:**
1. Paste 129, then 130, into the Supabase SQL editor.
2. Verify: anon `GET /rest/v1/notifications` → 401; anon `providers` → 401; on
   a phone, create a post with a photo, apply to it from the other account,
   change a profile photo — all succeed; the A21s and S20+ notification bells
   still load.
3. Approve and apply 131; deploy the dashboard (`vercel --prod` from
   admin-dashboard/ — it does not auto-deploy).
4. Release the app fixes (next version ≥ 1.0.9+10, WSL build).
5. Server-side payments kill switch (D10) before `MPESA_ENV=production`.
