# Trust & Safety + admin alerts — production rollout

Last updated: **2026-09-27**. Read `docs/HANDOFF.md` §0 first — its standing
rules apply here unchanged.

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
(116 → 115 → 114). Backend: redeploy `65ca515` from Render. Dashboard: promote
the previous Vercel deployment.

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
