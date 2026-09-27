# Trust & Safety — database tests

Migrations 114–116 applied to a local Postgres 17.6 replica of the live schema,
then exercised as the real roles PostgREST uses (`anon`, `authenticated`,
`service_role`) with `request.jwt.claims` set per statement.

Nothing here touches the linked Supabase project except `refresh-replica`, which
reads the live schema in a read-only transaction.

## Run

```sh
cd supabase/tests/trust-safety
npm install
npm test               # every test
npm test -- "ledger"   # only tests whose name matches the regex
```

The first run downloads an embedded Postgres binary (`embedded-postgres`) and
creates a cluster in `.pgdata/` (git-ignored). Port 54329, or set `TS_PG_PORT`.

## Files

| File | What it is |
| --- | --- |
| `replica_schema.sql` | The live schema as of the last refresh (tables, constraints, indexes, RLS, grants, functions) plus a prelude that recreates the Supabase roles, `auth.jwt()` and the extensions. **Generated — do not edit by hand.** |
| `refresh-replica.mjs` | Regenerates `replica_schema.sql` from the linked project (`npx supabase db query --linked`, read-only). Afterwards run `git checkout -- supabase/.temp/cli-latest`: the CLI rewrites that tracked file. |
| `report_taxonomy.json` | The report categories and per-target lists. Shared with `backend/src/moderation/moderation.constants.spec.ts` and `mobile-app/test/trust_safety_test.dart`, so the three layers cannot drift. |
| `harness.mjs` | Starts the cluster, creates a UTF-8 database, applies the replica and the migrations (twice, to prove they are re-runnable). |
| `db.test.mjs` | The tests: taxonomy, report filing and abuse limits, RLS and grants, every moderation RPC and its rules, ledger immutability and hash-chain tamper detection, enforcement for each restriction kind, fail-open behaviour, confidentiality of `my_account_status()`, and the full request → apply → select → pay → complete → approve/dispute flow with active and banned parties. |

## Why a replica and not `supabase db push`

The `migrations/` folder does not describe live (see the repo notes on migration
drift): replaying it would run 006, which wipes data, and 011, which breaks
sign-up. These tests therefore start from what production actually is, and
apply only 114–116 on top — the same thing that will happen in production.
