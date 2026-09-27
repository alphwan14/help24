# Trust & Safety + admin alerts — production rollout

Last updated: **2026-09-27**. Read `docs/HANDOFF.md` §0 first — its standing
rules apply here unchanged.

> **STATUS: COMPLETE (2026-09-27, 12:40–13:00 UTC).** 114, 115 and 116 are
> applied; `help24-backend` and the admin dashboard are deployed; every
> production check passed. Evidence is in [Rollout log](#rollout-log-2026-09-27)
> at the end of this file. The mobile app release was NOT part of this and has
> not been done.

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
