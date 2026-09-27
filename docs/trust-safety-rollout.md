# Trust & Safety + admin alerts — production rollout

Last updated: **2026-09-27**. Read `docs/HANDOFF.md` §0 first — its standing
rules apply here unchanged.

> **STATUS: COMPLETE (2026-09-27, 12:40–13:00 UTC).** 114, 115 and 116 are
> applied; `help24-backend` and the admin dashboard are deployed; every
> production check passed. Evidence is in [Rollout log](#rollout-log-2026-09-27)
> at the end of this file. The mobile app release was NOT part of this and has
> not been done.
>
> **Follow-up (13:57–14:08 UTC): migration 117 and the four fixes for the bell's
> "3" are live and verified.** Details in
> [Follow-up: the bell's "3"](#follow-up-the-bells-3-117-2026-09-27).

## Approval on record

On 2026-09-27 the owner approved, in this order:

1. apply migration **114**, then **115**;
2. deploy the **backend** and the **admin dashboard**;
3. apply migration **116**;
4. re-verify everything against production;
5. commit in separate layers (done — see below).

The rollout stopped before step 1 only because the Supabase MCP tools were not
available in that session (they need a fresh session after OAuth). **Nothing
has been applied to production and nothing has been pushed.** The mobile app
release is NOT part of this approval.

## State at handoff

| Item | State |
|---|---|
| Local commits on `main` (not pushed; 8 ahead of `origin/main` = `65ca515`) | `5d3e444` db · `c50c79f` backend · `3a2fd95` admin · `d84ba4c` app · `a755284` db-tests · `1dede0b` backend (alert copy) · db-tests dry-run tool · this docs commit |
| Migrations 114 / 115 / 116 | Written, 74 DB tests green, dry-run proven locally. **Not applied.** |
| Backend (`help24-backend`, `srv-d7mjm2v7f7vs73f8qaqg`) | 732 tests green, boot in enforce mode clean (138 routes, 0 undeclared). **Not deployed.** Render auto-deploys `main` on `backend/` changes. |
| Admin dashboard (Vercel `help24-admin-dashboard`) | Builds clean. **Not deployed.** Does NOT auto-deploy from git: `npx vercel --prod --yes` ships the working tree (CLI is logged in as `alphwan14`). |
| Mobile app | 1162 tests green, debug APK builds. Release not approved. |

### Pre-flight evidence (read-only, 2026-09-27)

- Live schema of the 21 tables 114–116 touch was re-extracted
  (`refresh-replica.mjs`) — identical to the replica the tests ran against
  (only seven blank lines differed).
- None of the objects 114–116 create exist yet; `user_reports` has 0 rows and
  its `user_reports_not_self`, `…_reason_check`, `…_status_check` constraints
  are present; 0 users have `is_banned`; admins: 3 active `super_admin`,
  1 inactive `senior_admin`.
- Fingerprints (`docs/sql/trust-safety-fingerprints.sql`, read-only):

```
escrow            17  total 73250   ec96a9380a5e2d220cc862097cdf1f01
transactions      45  total 136375  5d2651c6b3541ef60ee939906cd7f542
disputes           4                ee8c9bd7dcb0000439be69db3a11bad3
job_completions    9                d8d9c9840445a342fb92b17a5704b143
posts             53                266273df0789b05427f084631eac12b5
users             18                1b8ec6c1507d76990f9922c939985b86
user_reports       0
```

After the rollout every row above must be byte-identical (the migrations do not
write to money tables; `users.is_banned` is only mirrored from a ban, and there
are none).

## Runbook

Use the Supabase MCP (`execute_sql`) for SQL. Do **not** use `apply_migration`
(it writes the migration ledger, which live deliberately keeps empty) and never
`supabase db push` (HANDOFF §4.10). The Supabase CLI
(`supabase db query --linked -f <file>`) is the fallback.

### 0. Before anything
- Confirm the Render workspace with the owner: **My Workspace**
  (`tea-d48881c9c44c73b0gefg`). Touch only `help24-backend`.
- Re-run the fingerprints; they must match the table above.
- `git fetch && git status -sb` — `main` must still be only ahead of `origin`.

### 1. Dry run all three (HANDOFF rules 3–4)
```
cd supabase/tests/trust-safety && npm install && node dry-run.mjs --local
```
Then execute the generated file (path is printed) against production. The
expected result is an **error** starting `HELP24_DRY_RUN_OK` — everything was
applied inside one `DO` block and rolled back by construction. Any other
error: stop and fix before applying anything.

### 2. Apply 114, then 115
Execute the full contents of `supabase/migrations/114_trust_safety_schema.sql`
(it carries its own `BEGIN; … COMMIT;`), then 115. After each:
```sql
select relname from pg_class where relname in ('account_restrictions','moderation_actions');
select proname from pg_proc where proname like 'moderation\_%' order by 1;
select has_function_privilege('anon', 'public.my_account_status()', 'EXECUTE') as anon_can_read_status,  -- false
       has_function_privilege('authenticated', 'public.my_account_status()', 'EXECUTE') as users_can;  -- true
```

### 3. Deploy the backend, then the dashboard
```
git push origin main          # Render deploys help24-backend (backend/ changed)
```
Watch the deploy with the Render MCP until live, then in its logs expect
`[AUTH][ROUTES] 138 routes … undeclared=0` and a clean `[MODERATION_SELFCHECK]`
(it reads "enforcement inactive until migrations" only if 114/115 are missing).
```
cd admin-dashboard && npx vercel --prod --yes
```

### 4. Apply 116
Execute `supabase/migrations/116_trust_safety_enforcement.sql`, then confirm the
nine triggers (`trg_moderation_enforce_*`, `trg_posts_moderation_guard`,
`trg_chat_messages_undelete_guard`) exist.

### 5. Verify in production (read-only)
- Fingerprints — identical to the pre-flight table.
- `select * from public.moderation_audit_integrity where not (hash_ok and link_ok and seq_ok);` → 0 rows.
- `select public.moderation_denial(id, 'post') from public.users limit 5;` → all null.
- Backend (`B=https://help24-backend.onrender.com`):
  `curl -s $B/health` → ok; `curl -s -o /dev/null -w "%{http_code}" -X POST $B/reports` → 401;
  `$B/admin/alerts` and `$B/admin/moderation/summary` without a token → 401.
- Alerts against production: `node` the compiled `AdminAlertsService` with the
  service key (as in the session log) — the `reports` source must now be
  AVAILABLE (it was the only unavailable one before 114).
- Dashboard: open `/dashboard/trust-safety/queue` and the bell; Payments pages
  now list rows (they rendered empty before — see below).

### Rollback
Each migration's header lists its exact rollback. Roll back in reverse order
(116 → 115 → 114). Backend: redeploy **`959943d`** (`dep-daqt46avcj2c739qb910`,
the deploy that was live before this rollout) from Render — not `65ca515`, which
touched no `backend/` file and was never deployed. Dashboard: promote the
previous Vercel production deployment (the one this build restored its cache
from, `8zU2fDYaAMdzMGy7bRTK47NV3L89`).

## What the alerts will show on day one

Computed read-only against production on 2026-09-27: 3 payouts with no M-Pesa
result for ~100 days (KES 1,860 — use **Check with M-Pesa** on the Escrow
page), KES 1,250 owed to a provider from a split decision, KES 270 frozen as
"disputed" with no open dispute, the 5 orphaned escrow holds from HANDOFF §4.6
(do not delete by hand — `escrow-cleanup-design.md`), 3 STK payments never
confirmed, 2 paid jobs with no progress (one listing no longer exists), and
unanswered requests.

## Findings fixed in this work (already committed)

- **Every payments page rendered an empty table.** Live
  `transactions.post_id` has no foreign key to `posts`, so the
  `posts(title)` embed errored and the pages ignored the error (45
  transactions existed). Titles are now looked up by id and a failed read
  shows an error.
- Those pages and Active jobs were prerendered at build time (stale); they
  now render per request.
- `refresh-replica.mjs` failed on Windows (cmd.exe and a multi-line
  argument); it now passes SQL via `-f`.

## Found, not changed (pre-existing)

`notifications` readable/updatable by anon; `posts`/`applications` accept anon
inserts with any author id; `post_images` deletes open to public; chat
participants can edit each other's messages; `users` anon-readable.

## Rollout log (2026-09-27)

Executed by Claude under the owner's approval of 2026-09-27. All SQL went
through the Supabase MCP `execute_sql` (never `apply_migration`, never
`supabase db push`), so the migration ledger is still empty, as intended.

| # | Step | Evidence |
|---|---|---|
| 0 | Pre-flight | Supabase MCP tools present. Fingerprints re-run: all seven rows identical to the pre-flight table above. `git fetch`: `main` 8 ahead / 0 behind `origin/main`. Render service confirmed: `help24-backend`, owner `tea-d48881c9c44c73b0gefg`, branch `main`, rootDir `backend`, auto-deploy on commit. |
| 1 | Dry run 114–116 | `node dry-run.mjs --local` passed. The same generated SQL against production returned `ERROR P0001: HELP24_DRY_RUN_OK: 114, 115 and 116 applied cleanly inside one transaction and were rolled back`. Afterwards: 0 new tables, 0 moderation functions, 0 new `user_reports` columns, 0 moderation triggers left behind. |
| 2a | Apply 114 | `account_restrictions`, `moderation_actions` exist; 8 moderation functions; `anon` cannot execute `my_account_status()`, `authenticated` can; 0 restrictions / 0 actions / 0 reports (no legacy bans to import). |
| 2b | Apply 115 | 16 `moderation_*` functions; `authenticated` cannot execute `moderation_apply_sanction`, `service_role` can. |
| 2c | Byte-identity | Because the SQL was sent by hand, production was compared with a local replica built from the repo files (`pg_get_functiondef` / constraint / index / trigger / view / column hashes). After 115: all six fingerprints identical (23 functions, 46 constraints, 22 indexes, 9 triggers, 2 views, 25 `user_reports` columns). |
| 3a | Backend | `git push origin main` (`65ca515..fae99c2`). Render deploy `dep-dash1k0473hc73frbtjg` for `fae99c2`: build 12:49:20 → live 12:50:17 UTC. Boot log: `[AUTH][ROUTES] 138 routes — firebase=49 admin=66 public=23 undeclared=0 (mode=enforce)`, `[MODERATION_SELFCHECK] ✓ moderation schema present — account restrictions enforced.`, `[ADMIN_AUTH_SELFCHECK] ✓ 3 active admin(s)`. No DI errors. (The Redis-degraded and narrowed-auth warnings are pre-existing.) |
| 3b | Dashboard | `npx vercel --prod --yes` → `dpl_sJbVCvCrCyj6eSHnUVezKMM12pGP` READY, aliased to `https://admin.help24.co.ke`. Build clean; `/dashboard/trust-safety/*` and `/api/admin/alerts` in the route table; payments pages are dynamic (`ƒ`). |
| 4 | Apply 116 | All nine triggers present and enabled (`O`): `trg_moderation_enforce_{posts,post_images,applications,chats,chat_preview,chat_messages,message_edits}`, `trg_posts_moderation_guard`, `trg_chat_messages_undelete_guard`. Byte-identity re-run after 116: all six fingerprints identical to the replica (26 functions, 18 triggers). |
| 5 | Verify | **Fingerprints:** escrow 17/73250/`ec96a938…`, transactions 45/136375/`5d2651c6…`, disputes 4/`ee8c9bd7…`, job_completions 9/`d8d9c984…`, posts 53/`266273df…`, users 18/`1b8ec6c1…`, user_reports 0 — **byte-identical to pre-flight.** `moderation_audit_integrity` bad rows: 0. `moderation_denial(id,'post')` non-null across all 18 users: 0. **HTTP:** `/health` database healthy (overall `degraded` = Redis only, pre-existing); `POST /reports` 401; `GET /admin/alerts` 401; `GET /admin/moderation/summary` 401; `/promotions/campaigns` 401; `/feed` 200; control 404; `/config` ETag still `W/"3b6c0888a44bf4c1"`. Dashboard: `/login` 200; `/dashboard/trust-safety/queue` without a session 307 → `/login`; `/api/admin/alerts` without a session 401. **Alerts:** compiled `AdminAlertsService.compute()` against production: `unavailable: []` (the `reports` source now answers), 8 alerts — 1 payment needs reconciling, 1 provider owed from a split decision, 3 payouts with no M-Pesa result, 5 escrow holds with no payment, 3 payments never confirmed, 2 paid jobs with no progress, 1 urgent request with no responses, 1 request unanswered for a day — matching the day-one prediction above. |

### Signed-in end-to-end (2026-09-27, 13:04 UTC)

Run with the owner's dev admin login (`super_admin`), which the owner supplied and
authorised for this check. It replays the dashboard's own login: Supabase
password sign-in (session cookie written by `@supabase/ssr`) → the dashboard's
`POST /api/admin/session/restore` → `h24_admin_token` cookie. Everything after
sign-in was GET only.

- **Login:** restore → `200 {"connected":true,"role":"super_admin"}`; admin
  cookie set. A forged bearer token is still refused (401).
- **Dashboard pages, signed in — all 200, none redirected, no error text:**
  overview; Trust & Safety queue / reports ("No reports yet") / restricted /
  suspended / banned / audit; Payments all (46 `<tr>` = header + **45
  transactions** — this page rendered EMPTY before the fix), completed (10),
  pending (4), failed (32), escrow (11); Active jobs (19); Users (19 = header +
  18).
- **Alerts bell** (`/api/admin/alerts` through the dashboard): 200,
  `unavailable: []`, the same 8 alerts, each linking to its admin page.
- **Backend with the minted admin token:** `/admin/me` super_admin;
  `/admin/moderation/summary` all zeros; `/reports` `{"total":0}`;
  `/restricted` `[]`; `/audit` `{"total":0}`; `/audit/integrity`
  `{"intact":true, edited_rows:0, broken_links:0, sequence_gaps:0}`;
  `/admins` 3; `/admin/alerts` 8 with none unavailable.

Still deliberately not exercised: a moderation **write** in production (filing
a report, applying/lifting a sanction, hiding content) — each is a production
write outside this approval. The 74 DB tests cover those paths on the replica.

## Follow-up: the bell's "3" (117, 2026-09-27)

The owner asked why the bell's "3" never cleared, even after an admin reviewed
it. Part of that was by design: alerts are derived from records, so they clear
when the records are fixed. The rest was wrong, in three ways:

- all three alerts were June **sandbox** test records (the Daraja cutover was
  never done; `MPESA_ENV=sandbox`);
- the product had no way to fix two of them;
- acknowledging was per-browser, and got forgotten whenever one check was
  briefly unavailable.

The owner approved four fixes. Commits: `25a6e9f` db, `7f501a6` backend,
`19f35a2` admin.

| Fix | What changed |
|---|---|
| 1. Acknowledgements that came back | The dashboard kept acknowledgements in one browser's localStorage. It also *pruned* every acknowledgement whose alert was missing from a response. So a single poll where the payments check was unavailable wiped them, and the 3 returned. Removed, and replaced by fix 3. |
| 2. Test money off the bell | While `MPESA_ENV` is not `production`, every money finding is test money. It is reported as ONE LOW `sandbox_money` alert, and each line names the state its record was left in. After the cutover, `MPESA_PRODUCTION_SINCE` keeps earlier records classed as tests (see below). |
| 3. Shared "Mark reviewed" | `admin_alert_reviews` (117) is append-only: one row per review or reopen, bound to the alert's fingerprint (the exact records shown), with the admin and a reason of 5–500 characters. Every admin sees who reviewed it and why. A record joining or leaving the alert changes the fingerprint and raises it again. The badge counts unreviewed HIGH only. Route: `POST /admin/alerts/:id/reviews` (support_agent and up). |
| 4. Real fix paths | Closed disputes get a "Money after the ruling" panel (`GET /admin/finance/disputes/:id/money`, support_agent and up). Senior admins have two actions. **Apply the recorded ruling** (`admin_apply_recorded_ruling`) moves money that a legacy resolve left frozen; for a FULL_RELEASE it then dispatches the payout. **Record a share as paid** (`admin_record_manual_settlement`) takes the amount from the ruling, never from the request. Both write a row to `admin_finance_actions` in the same transaction. |

### Rollout log

| # | Step | Evidence |
|---|---|---|
| 1 | Dry run 117 | Local replica, with 114–116 applied first: `HELP24_DRY_RUN_OK`, nothing left behind. Production, same generated SQL: `HELP24_DRY_RUN_OK: 117 applied cleanly…`. Money-table fingerprints were identical before and after. |
| 2 | Apply 117 (~13:58 UTC) | Sent with `supabase db query --linked -f`: the Supabase MCP was not authorised in that session, and the migration ledger stays empty as intended. Created 2 tables, 3 functions and 4 append-only triggers, with RLS on both tables. Grants: service_role SELECT+INSERT on reviews, SELECT on finance actions. EXECUTE on both functions: anon false, authenticated false, service_role true. **10/10 schema hashes identical to the tested replica.** Money tables byte-identical before and after. |
| 3 | Backend | Pushed `fae99c2..19f35a2`. Render deploy `dep-dasi2mbncjis73ehfldg`: build 13:59:53, live 14:00:50 UTC. Boot log: `[AUTH][ROUTES] 142 routes — firebase=49 admin=70 public=23 undeclared=0 (mode=enforce)` (4 new admin routes); `AdminAlertsModule` and `FinanceRepairsModule dependencies initialized`; `[MODERATION_SELFCHECK] ✓`; `[ADMIN_AUTH_SELFCHECK] ✓ 3 active admin(s)`; `Daraja → SANDBOX`. The only warnings since boot are the pre-existing Redis-degraded and narrowed-auth banners. |
| 4 | Dashboard | `npx vercel --prod --yes` gave `dpl_4t9aZZxaEbz4W5NK1vEJ2h6N8qXn`, READY and aliased to `admin.help24.co.ke`. It compiled, and types and lint passed. `/dashboard/disputes/[id]` and `/api/admin/alerts` are dynamic. |
| 5 | Verify (read-only) | Below. |

**HTTP.** Each new route was probed with no token and with a forged token, on
both `help24-backend.onrender.com` and `api.help24.co.ke`. Every probe returned
401:

- `GET /admin/alerts`
- `POST /admin/alerts/{payout_stuck,sandbox_money}/reviews`
- `GET /admin/finance/disputes/:id/money`
- `POST /admin/finance/transactions/:id/manual-settlements`
- `POST /admin/finance/disputes/:id/apply-ruling`

Controls: `/health` 200 (degraded is Redis, pre-existing), `POST /reports` 401,
`/feed` 200, an unknown path 404.

The dashboard, with no session:

- `/login` 200;
- `/dashboard`, `/dashboard/disputes/:id`, `/dashboard/payments` and
  `/dashboard/trust-safety/queue` all 307 → `/login`;
- `/api/admin/alerts` 401.

**Alerts.** Computed with the deployed code against production, with
`MPESA_ENV=sandbox` as on Render. `unavailable: []` — the new `reviews` check
answers. There are 4 alerts and **the badge is 0**:

- MEDIUM `reports_untriaged` 1: the first real report (see below).
- MEDIUM `urgent_unanswered` 1.
- LOW `sandbox_money` 15. These are the records behind the former 3 HIGH and
  3 MEDIUM money alerts, and each line says the state it was left in:
  - 1 where the records disagree (Cook, KES 270 frozen as disputed);
  - 1 provider owed from a split;
  - 3 payouts with no M-Pesa result;
  - 5 holds with no payment;
  - 3 payments never confirmed;
  - 2 paid jobs with no progress.
- LOW `requests_unanswered` 1.

Contrast: the same data with `MPESA_ENV=production` gives 3 HIGH alerts
(`money_mismatch` 1, `provider_owed` 1, `payout_stuck` 3) and a badge of 3.
Detection is unchanged; only the classification moved.

**Money panels.** `FinanceRepairsService.money()` on all 4 disputes (all
closed):

| Dispute | Ruling | Payment / escrow | Panel |
|---|---|---|---|
| `e0bb9f2e` (Cook) | FULL_RELEASE | disputed / disputed | Frozen. **Apply the recorded ruling…** is offered. |
| `879ee132` (split) | PARTIAL_SPLIT | refunded / refunded | Provider share KES 1,250 **owed**, and **Record as paid…** is offered. Client refund KES 1,250 paid. 3 ledger legs. |
| `f6d6df1f`, `18f72f6a` | FULL_RELEASE | payout_pending | Nothing to apply: the payout is waiting on M-Pesa (Escrow → Check with M-Pesa). |

**Fingerprints after deploy and verification**, byte-identical to before 117:

- escrow 17 / 73250 `ec96a938…`
- transactions 45 / 136375 `5d2651c6…`
- settlements 7 / 3585 `31f82c35…`
- disputes 4 `ee8c9bd7…`
- dispute_decisions 4 `893e24ab…`
- job_completions 9 `d8d9c984…`

`admin_alert_reviews` has 0 rows, `admin_finance_actions` has 0 rows, and all 4
append-only triggers are enabled.

**First real report.** `user_reports` went from 0 to 1 at 13:43 UTC: a
`misleading_listing` report on an offer, made with `source: api` (through
`POST /reports`), snapshot captured, status `new`. It is the MEDIUM alert above
and waits, untriaged, in the Trust & Safety queue.

### Deliberately not done

- **No financial correction was run on the June sandbox records**: no ruling was
  applied and nothing was recorded as paid. They are test money, and they now
  sit in the LOW test alert. The repair actions are there for real cases.
- **No review was written in production.** Review rows are append-only and
  cannot be deleted, so the first one should be a real admin decision.
- **The signed-in check is still owed by the owner.** Sign in at
  `admin.help24.co.ke`, then check:
  1. The bell shows no number, shows a dot (for the 2 MEDIUM alerts), and lists
     the LOW test-payments card.
  2. Mark reviewed on any alert asks why. Afterwards the card shows who
     reviewed it and why, for every admin, and Reopen undoes it.
  3. The Cook dispute page shows "Money after the ruling" as frozen, with Apply
     offered. Do not apply it to test money unless you intend to.

### Rollback

Roll back in reverse order: the dashboard (promote
`dpl_sJbVCvCrCyj6eSHnUVezKMM12pGP`), then the backend (redeploy `fae99c2`, deploy
`dep-dash1k0473hc73frbtjg`), then 117 (the exact statements are in its header).

### At the Daraja cutover

Set `MPESA_PRODUCTION_SINCE` (the cutover time, ISO 8601) on `help24-backend`
in the same change as `MPESA_ENV=production`. Without it, every June test record
becomes a HIGH alert again. That is deliberate: unset is the noisy side, never
the silent one.

### Owner check, done in production

Between 14:33 and 14:40 UTC the owner (`alphwan14@gmail.com`, super_admin) used
the bell for real. `admin_alert_reviews` holds four rows, and the backend log
shows a `201` and an `[ALERTS] … by=` line for each:

1. `urgent_unanswered` reviewed ("Already reviewed");
2. `reports_untriaged` reviewed ("Reviewed");
3. `urgent_unanswered` reopened;
4. `urgent_unanswered` reviewed again.

Both alerts are quiet for every admin, and the medium dot is gone. Still not
exercised: the money panel on a closed dispute. No
`GET /admin/finance/disputes/:id/money` has succeeded, and
`admin_finance_actions` is empty.

## Follow-up 2: alert actions that work (2026-09-27)

The owner asked whether "Find a provider" actually works. It did not. It linked
to a read-only list of requests showing a name or email, with no phone numbers,
no matching, and no way to contact or invite anyone. The dashboard cannot
message a user at all outside a dispute.

An audit of all 17 alert actions against the pages they open found:

- **7 had a real control behind them:** triage and claim reports, decide or
  respond on disputes, approve or reject promotions, Check with M-Pesa, and
  record a provider payment.
- **3 were honest views or off-dashboard instructions.**
- **6 promised something no page could do:** "Find a provider", "Recruit
  supply", "Nudge the client", "Check in with both parties", "Follow up with the
  client", and "Retry or pay out manually". For the last one, there is no retry
  button; `POST /mpesa/release-payout` is admin-only and not wired to any page.
- **"Reconcile the records" works only in part.** Only its
  frozen-after-a-closed-dispute shape has a repair.

Commits: `a9ce701` backend, `a713c2a` admin.

| Change | What it does |
|---|---|
| Truthful labels | Each label now names what the admin can do: "Call a matching provider", "See who could take them", "Call the client", "Call both parties", "Call the provider", "Investigate each payment". The failed-payout and mismatch descriptions say what the dashboard cannot do, and who can. A test pins the retired labels out. |
| Items open the listing | Every request and job item links to `/dashboard/marketplace/requests/:id`. A failed payout and a stalled paid job do too. One whose listing is gone falls back to the escrow page rather than a 404. Item ids are unchanged, so the reviews above still attach. |
| A page per request | It shows the client, with a tap-to-call number (`tel:+254…`), email and account standing. Once a provider is chosen, it shows them too, and where the job stands (payment, work, dispute). It lists every applicant with their number. While the request is open and unanswered, it shows **who could take it** (details below). |
| Requests list | Titles open the page, and the client's number is shown. A "Could take it" column marks supply gaps at a glance. |
| Active jobs | Shows the client and the provider by name and number, where it used to show a truncated provider id. |
| Offers | Renders per request. It was prerendered at build time, so it listed offers and numbers as of the last deploy. |

**Who could take it.** Each person on the list shows:

- their evidence: an open offer, or the trade on their profile;
- the distance, when both sides have map coordinates;
- their `provider_reputation` track record, as counts and never percentages;
- any open reports;
- whether they already applied.

Suspended and banned accounts are left out, and the page counts them. When
nobody fits, it says so plainly: a supply gap, which is recruited for outside
the dashboard.

**Matching** lives in `admin-dashboard/lib/provider-matching.ts` and is
tested with `npm test` (12 cases). It uses the backend feed's own three tiers
from `profession-match.ts`: same category, same trade group, or a trade word in
the text. It reads the same registry, turned around to find providers for a
post. Open offers count as evidence, resolved through the registry by name,
alias or category; so "Delivery", which is not a category name, reaches the
`delivery-rider` trade.

Two deliberate differences from the feed, both found in live data:

- **Text matches whole words.** The feed tests substrings, so "rider" would
  match "provider".
- **Unknown labels borrow a category.** A label the registry cannot place
  borrows a category that contains it ("Cleaning" → "House Cleaning"), but
  never claims "same work".

Every read on these pages that fails is shown as a failure, never as "nobody"
or "no applications".

**Rollout.** No migration was needed. The dashboard went first, so no alert
link could point at a page that did not exist yet.

| Step | Evidence |
|---|---|
| Local | Backend: 763 tests pass (15 pre-existing skips) and the build is clean. Dashboard: tsc OK; lint 140 files, 0 errors (the 2 warnings are pre-existing); build OK; `npm test` 12/12. |
| Dashboard | `dpl_HsQyW4DTta8E492yz9btkSW42jDL` READY at about 14:56 UTC, aliased to `admin.help24.co.ke`. It compiled and passed types and lint. `/dashboard/marketplace/requests/[id]`, `/requests`, `/active-jobs` and `/offers` are dynamic. |
| Backend | Render `dep-dasitdbncjis73eianj0` (`a713c2a`): build 14:56:53, live 14:57:50 UTC. Boot log: `142 routes — admin=70 undeclared=0 (mode=enforce)`, both self-checks ✓, `Daraja → SANDBOX`, no errors. |
| Verify | New and existing admin routes: 401 with no token and with a forged one. Dashboard pages: 307 → `/login`. `/health` 200 (degraded is Redis). Alerts computed with the deployed code: `unavailable: []`, badge 0, the new labels, and the owner's reviews still attached (fingerprints unchanged). Request and job items open the request page. Money tables byte-identical; `admin_finance_actions` 0. |
| Rollback | Promote `dpl_4t9aZZxaEbz4W5NK1vEJ2h6N8qXn`, then redeploy `19f35a2` (`dep-dasi2mbncjis73ehfldg`). |

**Against production (read-only, the deployed matcher over live data).** Of 21
open unanswered requests, 10 have nobody who could take them. The rest:

- **The urgent delivery request in Kisauni** has one person doing the same
  work: the only Delivery offer, in Shanzu, with a phone number. It carries the
  open "misleading listing" report, and the page shows that on the row.
- **Painting and Laundry show "nobody" correctly.** Their only matching offers
  belong to the account that posted the requests, and a client is never
  suggested to themselves.
- **Posho mill request:** found through the free-text trade "Posho Mill
  Grinder", as a mention. That person has no phone on file, so the page shows
  their email.

**Found, not changed:**

- **A registry defect.** The `delivery-rider` profession's `category_id` is
  `delivery`, but the category's id is `delivery-rider`. So the backend feed
  only links delivery riders to delivery requests through words in the text.
  The registry is generated from bundled assets, so the fix belongs there, not
  in a hand-edited row.
- **Stale pages.** `/dashboard/marketplace` (overview), `/completed`, `/jobs`
  and `/dashboard/insights/providers` are still prerendered at build time.
