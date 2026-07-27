# `docker-entrypoint-initdb.d` — opt-in bootstrap SQL

Anything ending in `.sql`, `.sql.gz` or `.sh` dropped in this directory is
executed **once**, in filename order, the first time the `help24_pgdata` volume
is initialised. It is **never** re-run afterwards, not even on `docker compose
up --build`. To re-run it you must destroy the volume:

```bash
docker compose --profile db down -v
docker compose --profile db up -d
```

The directory is intentionally empty. Nothing here is required for the API,
which does not use this database (see the `postgres` service comment in
`docker-compose.yml`).

## Do not symlink `supabase/migrations/` into here

It will fail, and it will fail halfway through — leaving a partially migrated
database that looks fine until a query breaks.

45 of the 83 migration files reference objects that only a Supabase stack
creates:

| Referenced object | Provided by |
| --- | --- |
| `auth.users`, `auth.uid()` | Supabase GoTrue |
| `service_role`, `authenticated`, `anon` roles | Supabase bootstrap |
| `storage.objects`, `storage.buckets` | Supabase Storage |
| `extensions.*` schema | Supabase image |

A stock `postgres:16-alpine` image has none of them, so the first migration that
touches `auth.uid()` aborts.

If you want the real Help24 schema locally, run the **Supabase CLI stack**
(`supabase start`) instead — it applies `supabase/migrations/` against a genuine
Supabase Postgres and gives you PostgREST too, which is what the NestJS backend
actually speaks. `DOCKER.md` § *Switching between Supabase and local Postgres*
has the full recipe.

## What this directory is genuinely useful for

- Seed/fixture data for future workers and queue tables that will use a real
  `pg` driver.
- Enabling extensions you want present from the first boot, e.g.:

  ```sql
  -- 01-extensions.sql
  CREATE EXTENSION IF NOT EXISTS "pgcrypto";
  CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
  ```

- Scratch schemas for rehearsing SQL before promoting it to a numbered file in
  `supabase/migrations/`.
