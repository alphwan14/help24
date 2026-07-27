# Help24 — Docker

Everything behind the API URL runs in containers. **Flutter does not**, and is
not going to.

---

## Contents

1. [What is containerised (and what is not)](#1-what-is-containerised-and-what-is-not)
2. [Architecture](#2-architecture)
3. [Quick start](#3-quick-start)
4. [Command reference](#4-command-reference)
5. [Environment management](#5-environment-management)
6. [Switching between Supabase and local Postgres](#6-switching-between-supabase-and-local-postgres)
7. [Profiles](#7-profiles)
8. [Networking](#8-networking)
9. [Volumes](#9-volumes)
10. [Health checks](#10-health-checks)
11. [Logging](#11-logging)
12. [Performance — every optimisation, explained](#12-performance--every-optimisation-explained)
13. [Security audit](#13-security-audit)
14. [Development workflow](#14-development-workflow)
15. [Production workflow](#15-production-workflow)
16. [Troubleshooting](#16-troubleshooting)
17. [Verification](#17-verification)
18. [Future architecture](#18-future-architecture)

---

## 1. What is containerised (and what is not)

| Component | Runs | Why |
| --- | --- | --- |
| NestJS API | **Container** | The deployable unit. Same image locally and in production. |
| PostgreSQL | **Container** (opt-in) | Local tooling and future workers. Not the app's datastore — see §6. |
| Redis | **Container** (opt-in) | Prepared, not yet used by any code. |
| pgAdmin | **Container** (opt-in) | Local-only DB browser. |
| **Flutter app** | **Native** | Deliberate. Hot reload, device/emulator access, Android Studio, platform toolchains and IDE debugging all degrade badly through a container. Containerising it costs a lot and buys nothing. |
| **Android Studio / SDK** | **Native** | Same reasoning. |
| Admin dashboard (Next.js) | **Native** | Out of scope for this pass; it deploys to Vercel. Adding it later is one more compose service. |

The mobile app keeps pointing at the same URL it always has:

| Where Flutter runs | API base URL |
| --- | --- |
| Android emulator | `http://10.0.2.2:3000` |
| iOS simulator | `http://localhost:3000` |
| Physical device on the same Wi‑Fi | `http://<your-laptop-LAN-IP>:3000` (requires `API_BIND=0.0.0.0`, the default) |

Nothing in the Flutter project needed to change.

---

## 2. Architecture

### Today

```
   Flutter app  (NATIVE — emulator / device / desktop)
        │  HTTP :3000
        ▼
┌─────────────────────────────────────────────────────────────┐
│  help24_edge                                                │
│  ┌───────────────────────────┐                              │
│  │  api  (help24-api)        │────► Supabase (PostgREST)    │
│  │  NestJS 10 · node:22      │────► M-Pesa Daraja           │
│  │  non-root · read-only fs  │────► Firebase Admin (FCM)    │
│  └──────┬─────────────┬──────┘                              │
└─────────┼─────────────┼─────────────────────────────────────┘
          │             │
┌─────────▼──────┐  ┌───▼─────────────┐
│ help24_data    │  │ help24_cache    │
│  postgres      │  │  redis          │   ← both opt-in, both
│  pgadmin       │  │                 │     idle by default
└────────────────┘  └─────────────────┘
       ▲
   pgdata vol            redisdata vol
```

`postgres` and `redis` share **no** network. Neither touches `edge`.

### The shape it grows into

Section §18 shows the target topology and exactly which of today's decisions
make each step a small change instead of a rewrite. Nothing beyond the four
services above is implemented — by design.

---

## 3. Quick start

**Prerequisites:** Docker Desktop running, and `backend/.env` populated.

```bash
# One-time, if you don't already have it
cp backend/.env.example backend/.env    # then fill in real values
cp docker.env.example docker.env        # optional: only to override defaults

# Start the API
docker compose up -d --build

# Confirm
curl http://localhost:3000/health
# {"status":"ok","service":"help24-backend","timestamp":"..."}

# Watch it
docker compose logs -f api
```

Then run Flutter exactly as you always have:

```bash
cd mobile-app && flutter run
```

---

## 4. Command reference

### Lifecycle

```bash
docker compose up -d --build            # build + start API
docker compose --profile db up -d       # + PostgreSQL
docker compose --profile cache up -d    # + Redis
docker compose --profile tools up -d    # + pgAdmin (pulls in PostgreSQL)
docker compose --profile full up -d     # everything

docker compose ps                       # what is running, and its health
docker compose stop                     # stop, keep containers
docker compose down                     # stop + remove containers (VOLUMES KEPT)
docker compose down -v                  # + DELETE volumes — destroys local DB data
docker compose restart api              # restart one service
```

### Rebuilding after a code change

```bash
docker compose up -d --build api        # rebuild + swap in one step
docker compose build --no-cache api     # force a clean build (dependency weirdness)
```

### Logs

```bash
docker compose logs -f api              # follow
docker compose logs --tail 100 api      # last 100 lines
docker compose logs --since 10m api     # last 10 minutes
docker compose logs -f                  # all services, interleaved
```

### Shell access

```bash
docker compose exec api sh                              # the API container
docker compose exec postgres psql -U help24 -d help24   # psql
docker compose exec redis redis-cli --no-auth-warning -a help24_local_redis
```

> The API container has a **read-only** filesystem, so you cannot install
> packages inside it. That is the point. Change the Dockerfile and rebuild.

### Inspecting

```bash
docker compose config                   # fully resolved compose file
docker compose config --services        # which services this profile activates
docker image inspect help24/backend:local --format '{{.Config.User}}'
docker inspect help24-api --format '{{json .State.Health}}'
docker stats                            # live CPU / memory
```

---

## 5. Environment management

Two files, deliberately separate, with one rule each.

| File | Holds | Read by | In git? |
| --- | --- | --- | --- |
| `backend/.env` | Application secrets: Supabase, M‑Pesa, Firebase, admin | The `api` container via `env_file:`, **and** `npm run start:dev` | **No** |
| `backend/.env.example` | Documented template of the above | Humans | Yes |
| `docker.env` | Infrastructure knobs: ports, binds, image versions, local DB/Redis creds | `docker compose --env-file docker.env` | **No** (`*.env`) |
| `docker.env.example` | Documented template of the above | Humans | Yes |

**Why the split.** `backend/.env` is the file with real credentials, and it has
exactly one consumer, so it stays easy to audit. `docker.env` is boring by
construction — throwaway local passwords and port numbers — so it can be read,
diffed and shared without care.

**Why the `api` container reuses `backend/.env` rather than getting its own
copy.** A second copy is a second thing to keep in sync, and env drift between
"works natively" and "works in Docker" is the single most common way a
Dockerised project rots. One file, both workflows, no drift.

### Secrets never enter an image

Three independent guards:

1. `backend/.dockerignore` excludes `.env`, `.env.*`, `*.pem`, `*.key`,
   `serviceAccount*.json`, `firebase-adminsdk*.json` — they are not even
   uploaded to the daemon.
2. The Dockerfile has no `ARG` or `ENV` carrying a credential, and no `COPY` of
   an env file. Build args are visible in `docker history`; runtime env is not.
3. Values are injected at container start by compose.

Firebase credentials are env vars (`FIREBASE_PROJECT_ID`, `FIREBASE_CLIENT_EMAIL`,
`FIREBASE_PRIVATE_KEY`) — there is no service-account JSON to mount. Keep the
literal `\n` escapes in the private key; `firebase-admin.service.ts` converts
them back to newlines.

### `docker.env` is not loaded automatically

Compose only auto-loads a file named `.env`. Every variable in `docker.env` has
an identical default baked into `docker-compose.yml`, so the defaults apply with
no flag. Pass the file only when you override something:

```bash
docker compose --env-file docker.env --profile full up -d
```

To stop retyping it:

```powershell
$env:COMPOSE_ENV_FILES = "docker.env"     # PowerShell, per shell session
```
```bash
export COMPOSE_ENV_FILES=docker.env       # bash/zsh
```

### Production

Render (and any other host) sets these as dashboard environment variables. No
file is uploaded, and none of this changes: the image reads `process.env`
regardless of who populated it.

---

## 6. Switching between Supabase and local Postgres

**Read this before assuming the `postgres` service backs the API. It does not.**

The backend accesses data solely through `@supabase/supabase-js`:

```ts
// backend/src/supabase/supabase.service.ts
this.client = createClient(
  this.configService.getOrThrow('SUPABASE_URL'),
  this.configService.getOrThrow('SUPABASE_SERVICE_ROLE_KEY'),
);
```

That is **PostgREST over HTTPS**, not the Postgres wire protocol. There is no
`pg` driver in `package.json` and no `DATABASE_URL` anywhere in the source. So
the API cannot connect to a bare Postgres container no matter what connection
string you give it.

It also could not use the schema if it could connect: **45 of the 83 files in
`supabase/migrations/` reference `auth.*`, `storage.*`, `service_role` or
`authenticated`** — objects that only a Supabase stack creates.

### The three configurations that actually exist

**A. Cloud Supabase — the default, and what production uses**

```dotenv
# backend/.env
SUPABASE_URL=https://<project-ref>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=<service-role-key>
```
```bash
docker compose up -d
```

**B. Local Supabase — real local parity, one env line changed**

This is the genuine "run against a local database" mode. The Supabase CLI starts
Postgres *plus* PostgREST, auth and storage, and applies
`supabase/migrations/` for you.

```bash
supabase start          # from the repo root; prints local URLs and keys
```

Then point the container at your host. From inside a container `localhost` means
the container itself, so use Docker Desktop's host alias:

```dotenv
# backend/.env
SUPABASE_URL=http://host.docker.internal:54321
SUPABASE_SERVICE_ROLE_KEY=<service_role key printed by `supabase start`>
```
```bash
docker compose up -d --force-recreate api
```

Switching back is the same two lines in reverse. Nothing else changes — not the
image, not the compose file.

**C. The `postgres` container — a real database for everything else**

```bash
docker compose --profile db up -d
psql "postgresql://help24:help24_local_dev@127.0.0.1:5432/help24"
```

Use it for: scratch SQL, analytics, rehearsing a migration before promoting it,
and as the datastore for the workers and queues that *will* use a `pg` driver.
Do not use it as a Supabase substitute.

> Compose already passes a working `DATABASE_URL` to the API
> (`postgresql://help24:...@postgres:5432/help24`). Nothing reads it today. It
> is there so that the day a worker or a direct `pg` client is introduced, the
> infrastructure needs no change at all.

---

## 7. Profiles

Modularity is implemented with compose profiles, so the default `up` is exactly
one container and nothing more.

| Profile | Services | Use for |
| --- | --- | --- |
| *(none)* | `api` | Everyday work. Mirrors production. |
| `db` | `api`, `postgres` | SQL work, worker development |
| `cache` | `api`, `redis` | When Redis-backed features start landing |
| `tools` | `api`, `postgres`, `pgadmin` | Browsing the local database |
| `full` | all four | Rehearsing the complete local stack |

Verify what a profile resolves to before starting it:

```bash
docker compose --profile tools config --services
# postgres api pgadmin
```

Two details worth knowing, both of which bit this setup during authoring:

- `api` declares `depends_on: {postgres: {required: false}, redis: {required: false}}`.
  `required: false` means *wait for it if it is part of this run, start happily
  if it is not*. Without it, the default `docker compose up` would fail on a
  dependency that no profile activated.
- `depends_on` does **not** activate a dependency's profile. `pgadmin` needs
  `postgres`, so `postgres` carries the `tools` profile explicitly. Omitting it
  produces `service "pgadmin" depends on undefined service "postgres"`.

---

## 8. Networking

Three segments instead of one shared bridge:

| Network | Members | Purpose |
| --- | --- | --- |
| `help24_edge` | `api`, `pgadmin` | Host-published traffic and outbound internet |
| `help24_data` | `api`, `postgres`, `pgadmin` | Database access only |
| `help24_cache` | `api`, `redis` | Cache/queue access only |

The property this buys: **`postgres` and `redis` share no network**, and neither
is on `edge`. A compromised Redis cannot port-scan the database. `api` is the
only service spanning all three — a deliberate, single, auditable blast radius.

### Published ports

| Service | Default publish | Rationale |
| --- | --- | --- |
| `api` | `0.0.0.0:3000` | Must be LAN-reachable so a **physical phone** can hit it. Set `API_BIND=127.0.0.1` in `docker.env` on untrusted networks. |
| `postgres` | `127.0.0.1:5432` | Loopback only — for local `psql`/DBeaver, nothing else. |
| `redis` | `127.0.0.1:6379` | Loopback only. |
| `pgadmin` | `127.0.0.1:5050` | Loopback only — it runs in no-login desktop mode, which is *only* safe because of this. |

Everything else communicates by service name over the internal networks and is
published nowhere.

### Optional hardening

`help24_data` can be made `internal: true` (commented in `docker-compose.yml`),
removing the database segment's route to the internet entirely so a compromised
database cannot exfiltrate outward. It also blocks host port publishing on some
Docker versions — flip it, then confirm `psql` from the host still works before
keeping it.

---

## 9. Volumes

| Volume | Mounted at | Contents |
| --- | --- | --- |
| `help24_pgdata` | `postgres:/var/lib/postgresql/data` | Database files |
| `help24_redisdata` | `redis:/data` | AOF persistence |
| `help24_pgadmin` | `pgadmin:/var/lib/pgadmin` | Saved queries, layout, preferences |

Named volumes rather than bind mounts: Docker owns the permissions (no uid
mismatch on Windows), and `docker compose down` cannot remove them by accident —
that requires an explicit `down -v`.

**Nothing else is persisted, on purpose.** No build artefacts (rebuilt from
source), no secrets (injected at runtime), no logs (stdout, rotated by the
logging driver).

```bash
docker volume ls | grep help24
docker volume inspect help24_pgdata

# Back up the local database
docker compose exec -T postgres pg_dump -U help24 help24 > backup.sql

# Restore
docker compose exec -T postgres psql -U help24 -d help24 < backup.sql
```

`PGDATA` points at a *subdirectory* of the mount (`/var/lib/postgresql/data/pgdata`)
because the Postgres image refuses to initialise into a non-empty directory, and
volume mount roots pick up platform metadata. This avoids that whole failure class.

---

## 10. Health checks

| Service | Check | Interval / start period |
| --- | --- | --- |
| `api` | `GET /health` over loopback, using `node` — no curl/wget dependency | 30s / 20s |
| `postgres` | `pg_isready -h 127.0.0.1` | 10s / 30s |
| `redis` | `redis-cli ping` → `PONG` | 10s / 10s |

Three details that make these meaningful rather than decorative:

- **The API check runs inside the container against `127.0.0.1`**, so it never
  traverses the published port and stays honest even if publishing is
  misconfigured.
- **Postgres is checked over TCP (`-h 127.0.0.1`), not the unix socket.** The
  socket comes up *during* `initdb`, so a plain `pg_isready` reports healthy
  while the server is still bootstrapping and rejecting real clients.
- **`start_period` covers boot.** Failures inside it do not count toward
  `retries`, so a slow first start is not mistaken for a broken service.

Dependency gating: `pgadmin` waits for `postgres: service_healthy`. `api` waits
for `postgres`/`redis` *only when they are part of the run* (`required: false`).

```bash
docker compose ps                                        # health column
docker inspect help24-api --format '{{json .State.Health}}'
```

---

## 11. Logging

- **Rotation is enforced on every service** via a shared YAML anchor:
  `json-file`, `max-size: 10m`, `max-file: 3` → a hard 30 MB ceiling per
  service. Without this, unbounded logs eventually fill the disk — and this
  backend ticks three 60-second sweeps, so it produces output continuously.
  The anchor means a service added later cannot silently ship without rotation.
- **Build noise removed**: `NPM_CONFIG_UPDATE_NOTIFIER/FUND/AUDIT=false` strips
  npm's banners, and drops an outbound audit request from every build.
- **pgAdmin quietened**: `PGADMIN_CONFIG_CONSOLE_LOG_LEVEL=30` (warnings up),
  because its default request log dominates `docker compose logs`.
- **Redis auth warning suppressed**: the healthcheck uses `--no-auth-warning`,
  which would otherwise print a credential warning to stderr every 10 seconds.

Application log levels are left alone. The startup route verification in
`main.ts` and the `[PROCESSOR]`/`[PROMO][SWEEP]` tags are deliberate
observability — the `docker-verify.ps1` script parses them.

```bash
docker compose logs -f api | grep PROCESSOR    # follow one subsystem
```

Shipping to a real log aggregator later is a change to the `x-logging` anchor
only (`driver: fluentd` / `awslogs` / `loki`), applied to every service at once.

---

## 12. Performance — every optimisation, explained

### Build

| Optimisation | Effect |
| --- | --- |
| **Manifests copied before source.** `COPY package*.json` → `npm ci` → *then* `COPY src`. | The install layer is keyed on the lockfile, not on your code. Editing a controller no longer re-runs a ~60 s install. This single ordering choice is the difference between a ~5 s and a ~90 s rebuild. |
| **BuildKit cache mount** `--mount=type=cache,target=/root/.npm`. | npm's tarball cache survives between builds but lives outside the image, so dependency reinstalls are fast and add **zero** bytes to any layer. |
| **`npm ci`, not `npm install`.** | Installs the lockfile exactly, fails on drift, never rewrites the lock. Reproducible, and faster (skips resolution). |
| **`prod-deps` built from `base`, not from `build-deps`.** | Pruning (`npm prune --omit=dev`) leaves removed packages in the parent layer — the image still carries their bytes. A clean install in a fresh stage means `@nestjs/cli`, `typescript`, `jest` and `ts-jest` exist in **no** shipped layer. |
| **`sharing=locked` on the cache mounts.** | `build-deps` and `prod-deps` can run concurrently without corrupting the shared npm cache. |
| **`.dockerignore` excludes `node_modules` and `dist`.** | Context drops from ~400 MB to a few hundred KB. Also prevents the host's Windows-native binaries being copied into a Linux image. |

### Image

| Optimisation | Effect |
| --- | --- |
| **Multi-stage; only `runner` is shipped.** | Source, devDependencies, npm cache and the TypeScript compiler are all left behind. |
| **Alpine base.** | ~55 MB base vs ~80 MB for `bookworm-slim`. |
| **`node_modules` copied before `dist`.** | Dependencies change rarely, source constantly. Ordering the stable layer first means a code-only rebuild re-pushes ~2 MB instead of ~150 MB. |
| **`COPY --chown`, never `RUN chown -R`.** | A separate `chown` duplicates the whole `node_modules` tree into a second layer — roughly 150 MB of pure waste. |

### Startup

| Optimisation | Effect |
| --- | --- |
| **`node dist/main.js` directly** — no `npm start` wrapper. | Removes an npm process from the tree and keeps node a direct child of the init, so signals are not swallowed by a shell. |
| **`dumb-init` as PID 1.** | SIGTERM reaches node immediately; shutdown is a graceful drain rather than a 10-second wait for SIGKILL. |
| **`start_period` on health checks.** | Dependent services are gated on *ready*, not on *started*, so nothing races a half-booted database. |
| **`--enable-source-maps`.** | Not a speed optimisation — a debuggability one. `dist/` already ships `.js.map`, so stack traces point at real `.ts` lines. Cost is paid only while constructing a stack trace, i.e. only when throwing. |

### Measuring

```bash
docker image inspect help24/backend:local --format '{{.Size}}'
docker history help24/backend:local --human --format '{{.Size}}\t{{.CreatedBy}}'
docker compose build --no-cache api    # honest cold-build timing
```

---

## 13. Security audit

| Control | Status | Where |
| --- | --- | --- |
| Runs as non-root | ✅ `USER node` (uid 1000) | Dockerfile |
| No privilege escalation | ✅ `no-new-privileges:true` on every service | compose (`x-hardening` anchor) |
| All capabilities dropped | ✅ `cap_drop: [ALL]` on `api` | compose |
| Read-only root filesystem | ✅ `read_only: true` + 64 MB `/tmp` tmpfs | compose |
| Secrets absent from images | ✅ `.dockerignore` + no build ARGs + runtime injection | Dockerfile / `.dockerignore` |
| Secrets absent from git | ✅ `.env` and `*.env` ignored; only `*.example` committed | `.gitignore` |
| Minimal attack surface | ✅ Alpine, prod deps only, no npm/compiler/curl in the runtime image | Dockerfile |
| Unnecessary ports closed | ✅ Only `api` is non-loopback; DB/cache/tools are `127.0.0.1` | compose |
| Network segmentation | ✅ `postgres` and `redis` share no network | compose |
| Redis authentication | ✅ `--requirepass`, even on a loopback-only service | compose |
| Deterministic dependencies | ✅ `npm ci` against a committed lockfile | Dockerfile |
| Graceful shutdown | ✅ `dumb-init` + `enableShutdownHooks()` + 30 s grace | Dockerfile / `main.ts` |

**Why a read-only filesystem is safe here.** The service writes nothing to disk:
configuration is env, state is Supabase, logs are stdout. If a future dependency
needs scratch space and crashes with `EROFS`, the fix is another `tmpfs` entry —
not deleting the line.

**Deliberately not done, and why.**

- *Docker secrets / an external secrets manager.* Correct for Swarm or
  Kubernetes; over-engineered for a single Render service reading env vars.
  Migrating later means replacing `env_file:` with `secrets:` — a localised change.
- *Image signing and SBOM generation.* These belong with CI/CD, which does not
  exist yet. `docker buildx build --sbom=true --provenance=true` slots in when it does.
- *Base image digest pinning.* Tags are mutable, so this matters for
  reproducible releases. The hook exists — set `NODE_IMAGE=node:22-alpine@sha256:<digest>`
  in `docker.env`. Left on a tag for now so local development keeps getting
  security patches automatically.

**Recurring hygiene:**

```bash
docker scout cves help24/backend:local     # or: trivy image help24/backend:local
```

---

## 14. Development workflow

### The everyday loop (recommended)

Docker is not a hot-reload environment. Keep the fast inner loop native and use
containers for what they are good at — dependencies and production parity.

```bash
# Terminal 1 — API, native, hot reload
cd backend && npm run start:dev

# Terminal 2 — supporting services only, if you need them
docker compose --profile db --profile cache up -d

# Terminal 3 — Flutter, native
cd mobile-app && flutter run
```

Both the native and containerised API read the **same** `backend/.env`, so
switching between them changes nothing else.

### Verifying against the real artefact

Before pushing anything that touches dependencies, the build, or startup:

```bash
docker compose up -d --build
pwsh -File scripts/docker-verify.ps1
```

This catches the class of bug that only appears in a production image — a
runtime dependency listed under `devDependencies`, a case-sensitive import path
that Windows forgave, a missing env var.

### Onboarding a new developer

```bash
git clone <repo> && cd help24
cp backend/.env.example backend/.env    # fill in credentials
docker compose up -d --build
curl http://localhost:3000/health
```

Three commands to a running backend. No Node version negotiation, no global npm
installs, no "works on my machine".

### Moving to a new laptop

Install Docker Desktop, clone, copy `backend/.env` across, `docker compose up -d
--build`. The Node toolchain, the build and every dependency come from the
image. Only Flutter and the Android SDK still need a native install — which is
the intended trade.

---

## 15. Production workflow

**Render deploys from source today and continues to work untouched.** Nothing in
this setup changed the build command, the start command, or the env var
contract. `docker compose` is local-only.

### Optional: switch Render to the Docker image

If you want production to run the exact artefact you test locally, set the
service's Environment to **Docker** with:

- Dockerfile path: `backend/Dockerfile`
- Docker context: `backend`

Render injects `PORT`; the app already honours it (`main.ts` reads
`process.env.PORT` and binds `0.0.0.0`). No other change is needed.

The upside is that "works locally" and "works in production" become the same
claim. Do it as its own deliberate change, with a rollback ready — not bundled
into an unrelated deploy.

### Production checklist

- [ ] `NODE_ENV=production`
- [ ] `CORS_ORIGINS` set to an explicit allowlist (unset means `*`)
- [ ] `ADMIN_AUTH_DEBUG=false`
- [ ] `MPESA_DEV_FORCE_SUCCESS` unset or `false` — the app hard-throws at boot if
      it is `true` while `NODE_ENV=production`
- [ ] `MPESA_ENV=production` and all callback URLs HTTPS (validated at startup)
- [ ] Firebase keys present, with `\n` escapes intact
- [ ] `/health` wired to the platform health check

---

## 16. Troubleshooting

### `docker compose up` fails: `env file ./backend/.env not found`

```bash
cp backend/.env.example backend/.env    # then fill it in
```

### Container exits immediately: `[Config] Missing required env variable: X`

`config/configuration.ts` validates at startup and refuses to boot on a missing
variable. Add `X` to `backend/.env` — `.env.example` documents every one.

### Container exits immediately: `Dev payment mode is not allowed in production`

`MPESA_DEV_FORCE_SUCCESS=true` while `NODE_ENV=production`. The image defaults
to `NODE_ENV=production`, so this trips the moment you containerise a `.env`
that had the dev flag on. Either set `MPESA_DEV_FORCE_SUCCESS=false`, or set
`NODE_ENV=development` in `docker.env`.

### `service "pgadmin" depends on undefined service "postgres"`

A profile was activated that does not include `postgres`. `depends_on` does not
activate a dependency's profile — that is why `postgres` lists `tools` in its
own `profiles`. Use `docker compose --profile tools config --services` to see
what a profile actually resolves to.

### Port 3000 already in use

The native `npm run start:dev` is probably still running. Either stop it, or:

```dotenv
# docker.env
API_PORT=3001
```
```bash
docker compose --env-file docker.env up -d
```

### Flutter cannot reach the API

| Symptom | Cause | Fix |
| --- | --- | --- |
| Emulator gets connection refused | Using `localhost` | Use `http://10.0.2.2:3000` |
| Physical device times out | `API_BIND=127.0.0.1` | Set `API_BIND=0.0.0.0` and check the firewall |
| Everything times out | Container not healthy | `docker compose ps` then `docker compose logs api` |

### Health check stuck in `starting`

`start_period` is 20 s. If it is still `starting` after ~60 s, the app has not
bound its port — `docker compose logs api` will show why. Confirm from inside:

```bash
docker compose exec api node -e "require('http').get('http://127.0.0.1:3000/health',r=>console.log(r.statusCode))"
```

### `EROFS: read-only file system`

Something is writing to disk. Add a targeted tmpfs rather than removing the
protection:

```yaml
tmpfs:
  - /tmp:size=64m,mode=1777
  - /app/.cache:size=32m
```

### `database directory is not empty` (postgres)

A stale volume. This **deletes local database data**:

```bash
docker compose --profile db down -v
docker compose --profile db up -d
```

### Build is slow every time

BuildKit cache mounts need BuildKit (default in modern Docker). Confirm it is
being used — the build output should show `[+] Building` with per-stage
`CACHED` lines. If not: `DOCKER_BUILDKIT=1 docker compose build api`.

### Registry pulls time out

`docker info | grep -i proxy` — Docker Desktop routes through
`http.docker.internal:3128`, and a corporate proxy or VPN can break TLS to the
CDN. Symptom: `net/http: TLS handshake timeout` on `docker pull`. This blocks
builds entirely until the network path is fixed.

### Start over completely

```bash
docker compose --profile full down -v
docker image rm help24/backend:local
docker compose up -d --build
```

---

## 17. Verification

```powershell
pwsh -File scripts/docker-verify.ps1            # api only
pwsh -File scripts/docker-verify.ps1 -Full      # + postgres + redis
pwsh -File scripts/docker-verify.ps1 -Full -KeepUp
```

It checks, and fails loudly on any of:

1. Docker daemon reachable; `backend/.env` present
2. Compose project valid in **every** profile
3. `docker compose build api` succeeds
4. Final image size reported, and `User` is `node` (non-root)
5. Every container reaches `healthy` within 90 s
6. `GET /health` and `GET /` return `200` with `status: "ok"`
7. Boot log free of `Missing required env variable`, `FAILED TO LOAD`, and
   `Cannot find module`; startup route verification reports success
8. Postgres answers `select 1`; Redis answers `PING`
9. **Network segmentation is real** — proves Redis *cannot* reach Postgres,
   rather than trusting the config

Manual equivalents:

```bash
docker compose build api
docker compose --profile full up -d
docker compose ps
curl http://localhost:3000/health
docker compose exec postgres psql -U help24 -d help24 -c 'select 1'
docker compose exec redis redis-cli --no-auth-warning -a help24_local_redis ping
```

---

## 18. Future architecture

Target topology. **None of this is implemented** — the point is that each step
is additive.

```
Flutter (native)
      │
      ▼
   NGINX  ──────────── TLS, rate limiting, static assets
      │
      ▼
  NestJS API  ◄──────► Redis  ◄──────► Workers
      │                                   │
      ▼                                   ▼
  PostgreSQL                   Notification / SMS services
      │                                   │
      └──────────► Recommendation engine ─┘
                          │
                          ▼
                Prometheus → Grafana
```

What today's setup already did to make each step small:

| Next step | Why it is additive |
| --- | --- |
| **NGINX** | `help24_edge` exists and holds exactly one published service. NGINX joins `edge`, `api` drops its `ports:` block, and the API becomes unreachable except through the proxy. |
| **Redis adoption** | The service, network, persistence, auth and `REDIS_URL` all exist and resolve. Adoption is `npm i ioredis` plus a module — zero infrastructure change. |
| **Background workers** | The three `setInterval` sweeps in `event-processor`, `promotions-sweep` and `dispute-sla` are the workers, currently in-process. A worker service reuses the **same image** with a different `CMD`, joins `data` + `cache` and **no** `edge` — no inbound path, by construction. `DATABASE_URL` is already passed. |
| **Notification / SMS services** | New services on `edge` + `cache`. FCM credentials are already env-only, so nothing needs a mounted file. |
| **Recommendation engine** | Joins `data` + `cache`. The `noeviction` policy on Redis is already the correct one for a queue-backed pipeline. |
| **Prometheus / Grafana** | A `monitoring` profile plus a `metrics` network. Health checks are already machine-readable; adding a `/metrics` endpoint is the only app change. |
| **MinIO** | A service on `data` with its own volume. The volume pattern is established. |
| **CI/CD** | The Dockerfile already has an unused `test` stage — `docker build --target test ./backend`. Add `--sbom=true --provenance=true` for supply-chain attestation. |
| **Kubernetes** | Non-root, read-only rootfs, dropped capabilities, a real health endpoint and graceful SIGTERM handling are exactly what a `securityContext`, `readinessProbe` and `preStop` expect. The image needs no changes. |

### Deliberately not built yet

Every one of these is cheap to add later and costs real complexity now: NGINX
(nothing to proxy to but one service), Redis integration code (no consumer),
separate worker containers (in-process sweeps are correct at this scale),
Prometheus/Grafana (no `/metrics` endpoint yet), MinIO (Supabase Storage is in
use), Kubernetes (one service does not need an orchestrator), and Docker secrets
(env vars are the right fit for Render).

---

## File map

| File | Role |
| --- | --- |
| [backend/Dockerfile](backend/Dockerfile) | Multi-stage production image |
| [backend/.dockerignore](backend/.dockerignore) | Build context + secret exclusions |
| [docker-compose.yml](docker-compose.yml) | Service orchestration, networks, volumes |
| [docker.env.example](docker.env.example) | Infrastructure settings template |
| `docker.env` | Your local overrides (gitignored) |
| [backend/.env.example](backend/.env.example) | Application secrets template |
| `backend/.env` | Your real secrets (gitignored) |
| [docker/pgadmin/servers.json](docker/pgadmin/servers.json) | Preconfigured pgAdmin connection |
| [docker/postgres/init/](docker/postgres/init/) | Opt-in bootstrap SQL (empty; read its README) |
| [scripts/docker-verify.ps1](scripts/docker-verify.ps1) | Automated stack verification |
