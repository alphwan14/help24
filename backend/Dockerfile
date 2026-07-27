# syntax=docker/dockerfile:1.7
# =============================================================================
# Help24 backend (NestJS 10) — production image
# =============================================================================
# Build from the repo root:   docker compose build api
# Build directly:             docker build -t help24/backend:local ./backend
#
# Stage graph (each stage is a cache boundary — see DOCKER.md § Performance):
#
#   base ──┬── build-deps ── build ──┐
#          │                   └─ test (optional, CI only: --target test)
#          └── prod-deps ────────────┤
#                                    └──> runner   ← the only shipped stage
#
# The runner never sees: source, devDependencies, npm, the lockfile history or
# any .env file. It contains compiled JS + production node_modules, nothing else.
# =============================================================================

# Pinned to Node 22 LTS. package.json declares engines >=18, but 22 is the
# current LTS line with security support well past this project's horizon, and
# it matches the ES2021 target in tsconfig.json comfortably.
#
# Override to test a new runtime without editing this file:
#   docker build --build-arg NODE_IMAGE=node:24-alpine ./backend
#
# For reproducible production builds, pin by digest instead of tag — a tag is
# mutable and `node:22-alpine` today is not the same bytes as next month:
#   NODE_IMAGE=node:22-alpine@sha256:<digest>
ARG NODE_IMAGE=node:22-alpine


# ─────────────────────────────────────────────────────────────────────────────
# Stage: base — shared settings for every build stage
# ─────────────────────────────────────────────────────────────────────────────
FROM ${NODE_IMAGE} AS base

WORKDIR /app

# Silence npm's decorative output. This is the Phase 11 "no console spam" rule
# applied at build time: funding/audit/update banners add noise to CI logs and
# the audit call makes an outbound request on every single build.
ENV NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false


# ─────────────────────────────────────────────────────────────────────────────
# Stage: build-deps — full dependency tree (prod + dev), needed to compile
# ─────────────────────────────────────────────────────────────────────────────
FROM base AS build-deps

# Copy ONLY the manifests first. This is the single most important caching
# decision in the file: this layer is keyed on package.json + package-lock.json,
# so editing a controller does not re-run a ~60 s npm install. Copying `src`
# before installing would invalidate the install on every source edit.
COPY package.json package-lock.json ./

# `npm ci` (not `npm install`): installs exactly the lockfile, fails if
# package.json and the lock have drifted, and never mutates the lockfile —
# the three properties you want in a reproducible build.
#
# The BuildKit cache mount keeps npm's HTTP cache (~/.npm) OUTSIDE the image
# layer. Tarballs are reused across builds, but they add zero bytes to the
# final image and never appear in a layer.
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm ci


# ─────────────────────────────────────────────────────────────────────────────
# Stage: build — compile TypeScript to dist/
# ─────────────────────────────────────────────────────────────────────────────
FROM build-deps AS build

COPY tsconfig.json tsconfig.build.json nest-cli.json ./
COPY src ./src

# `nest build` honours nest-cli.json (deleteOutDir) + tsconfig.build.json
# (excludes *.spec.ts from the emitted output).
RUN npm run build

# Fail the BUILD, not the deploy, if the compiler silently emitted nothing.
# Without this a bad tsconfig produces a green build and an image that exits
# instantly at runtime with MODULE_NOT_FOUND.
RUN node -e "require('fs').accessSync('dist/main.js')" \
 && echo "[build] dist/main.js present"


# ─────────────────────────────────────────────────────────────────────────────
# Stage: test — optional, not part of the default build path
# ─────────────────────────────────────────────────────────────────────────────
# Nothing depends on this stage, so `docker build` skips it entirely. It exists
# so CI can run the suite in the same environment that produces the image:
#   docker build --target test ./backend
FROM build AS test
RUN npm test


# ─────────────────────────────────────────────────────────────────────────────
# Stage: prod-deps — production dependencies only
# ─────────────────────────────────────────────────────────────────────────────
# Deliberately built from `base`, NOT from `build-deps`. Pruning an existing
# tree (`npm prune --omit=dev`) leaves the removed packages in the parent layer,
# so the image still carries their bytes. A clean install in a fresh stage means
# @nestjs/cli, typescript, jest and ts-jest never exist in any shipped layer.
FROM base AS prod-deps

COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm ci --omit=dev


# ─────────────────────────────────────────────────────────────────────────────
# Stage: runner — the production image
# ─────────────────────────────────────────────────────────────────────────────
FROM ${NODE_IMAGE} AS runner

# dumb-init (~20 KB) becomes PID 1 and forwards signals to node. Without an
# init, node runs as PID 1 where the kernel gives it no default signal
# handlers, and `docker stop` degrades into SIGKILL after the timeout — which
# would kill the three background sweeps (event retry, promotions, dispute SLA)
# mid-write. With dumb-init + enableShutdownHooks() in main.ts, SIGTERM runs
# every onModuleDestroy() and drains in-flight HTTP before exit.
# It also reaps zombies, which matters the moment anything shells out.
RUN apk add --no-cache dumb-init

WORKDIR /app

ENV NODE_ENV=production \
    PORT=3000 \
    # dist/ ships .js.map (tsconfig sourceMap: true). This flag makes stack
    # traces point at the .ts line instead of a minified dist offset. The cost
    # is paid only while constructing a stack trace, i.e. only when throwing.
    NODE_OPTIONS=--enable-source-maps

# --chown on COPY sets ownership in one pass. A separate `RUN chown -R` would
# duplicate the entire node_modules tree into a second layer (~150 MB wasted).
#
# node_modules is copied BEFORE dist: dependencies change rarely, source changes
# constantly. Ordering the rarely-changed layer first means a code-only rebuild
# re-pushes ~2 MB instead of ~150 MB.
COPY --chown=node:node --from=prod-deps /app/node_modules ./node_modules
COPY --chown=node:node --from=build     /app/dist         ./dist
COPY --chown=node:node package.json ./

# The `node` user (uid/gid 1000) ships with the official image. Everything past
# this line runs unprivileged: a container escape lands on a user that owns
# nothing but /app and cannot install packages or write outside its own files.
USER node

# Documentation only — publishing is decided in docker-compose.yml. Listing it
# here is what lets `docker run -P` and orchestrators discover the port.
EXPOSE 3000

# Hits the existing GET /health (src/health.controller.ts) over loopback, so the
# check never leaves the container and never touches the published port.
#
# Implemented with node itself rather than curl/wget: no extra package, no extra
# attack surface, and it works identically if the base image is ever switched
# from alpine to bookworm-slim.
#
# start-period covers Nest's DI bootstrap + the startup route verification in
# main.ts; failures during that window do not count toward `retries`.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["node", "-e", "const r=require('http').get({host:'127.0.0.1',port:process.env.PORT||3000,path:'/health'},s=>process.exit(s.statusCode===200?0:1));r.setTimeout(4000,()=>{r.destroy();process.exit(1)});r.on('error',()=>process.exit(1))"]

ENTRYPOINT ["dumb-init", "--"]

# Exec form (no shell): node is a direct child of dumb-init, so signals reach it
# without a /bin/sh in between swallowing them.
CMD ["node", "dist/main.js"]
