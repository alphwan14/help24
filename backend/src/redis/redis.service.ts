import {
  Injectable,
  Logger,
  OnApplicationShutdown,
  OnModuleInit,
  Optional,
} from '@nestjs/common';
import Redis, { RedisOptions } from 'ioredis';
import { loadRedisConfig, redactUrl, RedisConfig } from './redis.config';
import { SCRIPT_NAMES, SLIDING_WINDOW_LUA, TOKEN_BUCKET_LUA } from './redis.scripts';

/**
 * The ONE place this backend talks to Redis.
 *
 * CONTAINMENT RULE
 * ----------------
 * Nothing outside this directory constructs a Redis client, and nothing
 * outside it knows what library backs one. Exactly two modules import
 * RedisModule — the rate limiter and the health checks — and both go through
 * the narrow surface below. That is deliberate: the failure behaviour of a
 * shared dependency has to be decided once, not re-litigated by every feature
 * that fancies a cache. When a future module wants Redis, it gets it from
 * here, with these timeouts and this fallback semantics already applied.
 *
 * THE CENTRAL DESIGN DECISION: REDIS MUST NEVER TAKE THE API DOWN
 * --------------------------------------------------------------
 * Every option below serves one property — a sick Redis degrades this service,
 * it does not stop it:
 *
 *   lazyConnect + non-blocking boot   a Redis that is down at startup produces
 *                                     a warning, not a crash loop.
 *   enableOfflineQueue: false         THE most important line here. ioredis
 *                                     defaults to queueing commands while
 *                                     disconnected and flushing them on
 *                                     reconnect. For a cache that is a
 *                                     kindness; for a rate limiter on the
 *                                     request path it is a disaster — every
 *                                     request would block until the connection
 *                                     recovers, converting a Redis outage into
 *                                     an API outage. Off, a command against a
 *                                     dead connection rejects in microseconds
 *                                     and the caller falls back locally.
 *   commandTimeout                    bounds a connection that is up but
 *                                     unresponsive, which offline-queue
 *                                     rejection does not cover.
 *   maxRetriesPerRequest: 1           one retry absorbs a dropped packet;
 *                                     more just multiplies latency on a
 *                                     dependency that is already failing.
 *
 * WHAT THIS SERVICE DOES NOT DO
 * -----------------------------
 * No caching helpers, no get/set sugar, no pub/sub. Phase 1 is infrastructure:
 * distributed coordination and health. Adding a `cache()` method here would
 * invite exactly the scattered usage this layer exists to prevent.
 */
@Injectable()
export class RedisService implements OnModuleInit, OnApplicationShutdown {
  private readonly logger = new Logger(RedisService.name);
  private readonly config: RedisConfig;

  private client: Redis | null = null;
  private shuttingDown = false;

  /** When the connection was first observed down. Null while healthy. */
  private unavailableSince: number | null = null;

  /**
   * Connection errors arrive once per reconnect attempt — several per second
   * during an outage. Logging each would bury the incident in its own noise,
   * so repeats inside this window are counted rather than printed.
   */
  private lastErrorLoggedAt = 0;
  private suppressedErrorCount = 0;
  private static readonly ERROR_LOG_INTERVAL_MS = 30_000;

  // `@Optional()` is REQUIRED here, not decorative: with emitDecoratorMetadata
  // on, Nest reads this parameter's design-time type and tries to resolve a
  // provider for it, and DI fails at boot. Marked optional, Nest passes
  // undefined and the config is loaded from the environment as intended.
  // The parameter exists so the integration test can point the service at a
  // throwaway Redis without mutating process.env.
  constructor(@Optional() config?: RedisConfig) {
    this.config = config ?? loadRedisConfig();
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  async onModuleInit(): Promise<void> {
    if (!this.config.url) {
      this.logger.warn(
        '[REDIS] REDIS_URL is not set — running in DEGRADED mode. Rate limits ' +
          'will be enforced per-instance only, and will not hold across replicas. ' +
          'Set REDIS_URL before running more than one instance in production.',
      );
      return;
    }

    this.client = new Redis(this.config.url, this.buildOptions());
    this.registerHandlers(this.client);
    this.registerScripts(this.client);

    // Wait for readiness, bounded. A reachable Redis is ready before the first
    // request arrives — worth waiting a moment for, because it avoids a burst
    // of spurious "degraded" fallbacks in the first seconds of a deploy. An
    // unreachable one must not hold the process hostage.
    //
    // The wait listens for the 'ready' EVENT rather than awaiting connect()'s
    // promise, and connect()'s rejection is swallowed. That is deliberate:
    // ioredis drives its own reconnect loop from the socket's close event, and
    // consuming the rejection as the primary signal would couple this
    // service's startup path to whether a rejected connect() also happens to
    // re-arm that loop. Listening to events keeps the two independent —
    // startup gives up after a bound, reconnection continues regardless.
    const ready = this.waitForReady(this.config.connectTimeoutMs);
    this.client.connect().catch(() => {
      // Reported through the 'error' handler; nothing to add here.
    });

    if (await ready) {
      await this.logServerIdentity();
      return;
    }

    this.markUnavailable();
    if (this.config.required) {
      // REDIS_REQUIRED=true is an explicit operator statement that degraded
      // mode is unacceptable here. Honour it: fail at boot, where an
      // orchestrator will hold the previous version in place, rather than
      // serving traffic with weaker guarantees than the operator asked for.
      throw new Error(
        `[REDIS] REDIS_REQUIRED=true and Redis at ${redactUrl(this.config.url)} was ` +
          `not ready within ${this.config.connectTimeoutMs}ms.`,
      );
    }
    this.logger.warn(
      `[REDIS] Not ready within ${this.config.connectTimeoutMs}ms ` +
        `(${redactUrl(this.config.url)}) — continuing in DEGRADED mode and ` +
        `retrying in the background.`,
    );
  }

  /** Resolve true on the next 'ready', false if `ms` elapses first. */
  private waitForReady(ms: number): Promise<boolean> {
    const client = this.client;
    if (!client) return Promise.resolve(false);

    return new Promise<boolean>((resolve) => {
      let timer: ReturnType<typeof setTimeout> | undefined;

      const settle = (ok: boolean): void => {
        if (timer) clearTimeout(timer);
        client.off('ready', onReady);
        resolve(ok);
      };
      const onReady = (): void => settle(true);

      client.once('ready', onReady);
      timer = setTimeout(() => settle(false), ms);
      timer.unref?.();
    });
  }

  /**
   * `onApplicationShutdown` rather than `onModuleDestroy`, because it runs
   * AFTER every module's destroy hook. A background sweep draining during
   * shutdown may still consume budget; closing the connection out from under
   * it would turn an orderly stop into a stream of connection errors.
   */
  async onApplicationShutdown(): Promise<void> {
    this.shuttingDown = true;
    const client = this.client;
    if (!client) return;
    this.client = null;

    try {
      // QUIT is the polite close: it lets in-flight replies land before the
      // socket goes away. Bounded, because a Redis that is already wedged must
      // not be the reason the process misses its SIGTERM grace period.
      await this.withTimeout(client.quit(), 2_000, 'quit');
      this.logger.log('[REDIS] Connection closed cleanly.');
    } catch {
      client.disconnect();
      this.logger.warn('[REDIS] Clean close timed out — socket force-closed.');
    }
  }

  // ── State ──────────────────────────────────────────────────────────────────

  /** True when a command issued right now would reach Redis. */
  get isAvailable(): boolean {
    return this.client?.status === 'ready';
  }

  /** True when Redis was never configured, as opposed to configured-but-down. */
  get isConfigured(): boolean {
    return this.config.url !== null;
  }

  /** ioredis connection status, verbatim, for diagnostics. */
  get status(): string {
    if (!this.config.url) return 'not_configured';
    return this.client?.status ?? 'uninitialised';
  }

  /** How long the connection has been down, in ms. Null while healthy. */
  get degradedForMs(): number | null {
    return this.unavailableSince === null ? null : Date.now() - this.unavailableSince;
  }

  /** Connection string with credentials removed — safe for logs and /health. */
  get safeUrl(): string {
    return redactUrl(this.config.url);
  }

  get keyPrefix(): string {
    return this.config.keyPrefix;
  }

  get commandTimeoutMs(): number {
    return this.config.commandTimeoutMs;
  }

  // ── Operations ─────────────────────────────────────────────────────────────

  /**
   * Round-trip PING with a hard timeout.
   *
   * Returns latency in ms, or null when Redis is unreachable. Never throws:
   * the health endpoint's job is to REPORT a dependency failure, not to become
   * one.
   */
  async ping(): Promise<{ ok: boolean; latencyMs: number | null; detail?: string }> {
    if (!this.client) {
      return { ok: false, latencyMs: null, detail: this.config.url ? 'not connected' : 'not configured' };
    }
    const startedAt = Date.now();
    try {
      const reply = await this.withTimeout(
        this.client.ping(),
        this.config.commandTimeoutMs,
        'ping',
      );
      const latencyMs = Date.now() - startedAt;
      if (reply !== 'PONG') {
        return { ok: false, latencyMs, detail: `unexpected reply: ${String(reply)}` };
      }
      return { ok: true, latencyMs };
    } catch (err) {
      return {
        ok: false,
        latencyMs: Date.now() - startedAt,
        detail: err instanceof Error ? err.message : String(err),
      };
    }
  }

  /**
   * Execute the sliding-window script. See redis.scripts.ts for semantics.
   *
   * Throws when Redis is unavailable — deliberately. The decision about what
   * an unavailable limiter means belongs to the rate limiter, which has a
   * local fallback; swallowing it here would hide a degradation that the
   * caller needs to react to and report.
   */
  async slidingWindow(
    key: string,
    windowMs: number,
    limit: number,
    cost: number,
    seed: string,
  ): Promise<ScriptResult> {
    return this.evalScript(SCRIPT_NAMES.slidingWindow, key, [
      windowMs,
      limit,
      cost,
      seed,
    ]);
  }

  /** Execute the token-bucket script. See redis.scripts.ts for semantics. */
  async tokenBucket(
    key: string,
    capacity: number,
    refillTokens: number,
    refillIntervalMs: number,
    cost: number,
  ): Promise<ScriptResult> {
    return this.evalScript(SCRIPT_NAMES.tokenBucket, key, [
      capacity,
      refillTokens,
      refillIntervalMs,
      cost,
    ]);
  }

  private async evalScript(
    name: string,
    key: string,
    args: Array<string | number>,
  ): Promise<ScriptResult> {
    const client = this.client;
    if (!client || client.status !== 'ready') {
      throw new RedisUnavailableError(this.status);
    }

    const invoke = client as unknown as Record<
      string,
      (key: string, ...args: Array<string | number>) => Promise<unknown>
    >;

    const raw = await this.withTimeout(
      invoke[name](key, ...args),
      this.config.commandTimeoutMs,
      name,
    );

    if (!Array.isArray(raw) || raw.length < 4) {
      throw new Error(`[REDIS] ${name} returned an unexpected shape: ${JSON.stringify(raw)}`);
    }
    const [allowed, limit, remaining, retryAfterMs] = raw.map((v) => Number(v));
    return {
      allowed: allowed === 1,
      limit,
      remaining: Math.max(0, remaining),
      retryAfterMs: Math.max(0, retryAfterMs),
    };
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  private buildOptions(): RedisOptions {
    return {
      // Nothing connects until onModuleInit says so, which keeps connection
      // failures inside a place that can decide what to do about them.
      lazyConnect: true,

      // See the class comment — the single most consequential option here.
      enableOfflineQueue: false,

      connectTimeout: this.config.connectTimeoutMs,
      commandTimeout: this.config.commandTimeoutMs,
      maxRetriesPerRequest: 1,

      // ioredis reconnects on its own; this only shapes the delay. Exponential
      // with a cap and jitter: a Redis restarting under load must not be met
      // by every backend instance reconnecting in lockstep at the same
      // millisecond, which is how a recovering dependency gets knocked over
      // again by its own clients.
      retryStrategy: (attempt: number): number | null => {
        if (this.shuttingDown) return null; // stop retrying during shutdown
        const backoff = Math.min(attempt * 200, this.config.maxReconnectDelayMs);
        const jitter = Math.floor(Math.random() * 200);
        return backoff + jitter;
      },

      // Some managed Redis providers (and load balancers) return READONLY when
      // a failover promotes a new primary. Reconnecting is the correct
      // response — the old socket points at a replica.
      reconnectOnError: (err: Error): boolean => err.message.includes('READONLY'),
    };
  }

  private registerHandlers(client: Redis): void {
    client.on('ready', () => {
      const downtime = this.degradedForMs;
      this.unavailableSince = null;
      if (downtime !== null) {
        this.logger.log(`[REDIS] Reconnected after ${Math.round(downtime / 1000)}s of degraded operation.`);
      } else {
        this.logger.log(`[REDIS] Connected — ${this.safeUrl} (keyPrefix="${this.config.keyPrefix}")`);
      }
    });

    client.on('end', () => {
      if (this.shuttingDown) return;
      this.markUnavailable();
      // 'end' means ioredis has STOPPED reconnecting — the retry strategy
      // returned a non-number. Ours only does that during shutdown, so
      // reaching here outside shutdown means the client is permanently dead
      // and every request will fall back forever. Silent permanent
      // degradation is the worst outcome this layer can produce, so it is
      // logged at error level rather than left to be inferred.
      this.logger.error(
        '[REDIS] Client has STOPPED reconnecting — rate limits are permanently ' +
          'degraded to per-instance until this process is restarted.',
      );
    });

    client.on('close', () => {
      if (!this.shuttingDown) this.markUnavailable();
    });

    // MUST exist. An ioredis client with no 'error' listener emits an
    // unhandled 'error' event, and Node's default action for that is to
    // terminate the process — a Redis blip would kill the API.
    client.on('error', (err: Error) => {
      this.markUnavailable();
      this.logConnectionError(err);
    });
  }

  private registerScripts(client: Redis): void {
    // defineCommand caches the script by SHA and transparently re-loads it
    // after a NOSCRIPT (which is what a Redis restart produces), so neither
    // the caller nor this service ever has to think about the script cache.
    client.defineCommand(SCRIPT_NAMES.slidingWindow, {
      numberOfKeys: 1,
      lua: SLIDING_WINDOW_LUA,
    });
    client.defineCommand(SCRIPT_NAMES.tokenBucket, {
      numberOfKeys: 1,
      lua: TOKEN_BUCKET_LUA,
    });
  }

  /**
   * Record the server version once, at connect.
   *
   * The Lua scripts read `redis.call('TIME')` and then write, which is only
   * safe from Redis 5 onward (effects replication). Printing the version turns
   * "are we on a supported server?" from an assumption into a logged fact, and
   * an unsupported one is called out rather than silently mis-limiting.
   */
  private async logServerIdentity(): Promise<void> {
    if (!this.client) return;
    try {
      const info = await this.withTimeout(
        this.client.info('server'),
        this.config.commandTimeoutMs,
        'info',
      );
      const version = /redis_version:([^\r\n]+)/.exec(String(info))?.[1]?.trim();
      if (!version) return;

      const major = Number(version.split('.')[0]);
      if (Number.isFinite(major) && major < 5) {
        this.logger.error(
          `[REDIS] Server version ${version} is NOT supported. The rate-limiting ` +
            `scripts call TIME before writing, which requires Redis >= 5 (effects ` +
            `replication). Upgrade the server — limits are not reliable on this version.`,
        );
      } else {
        this.logger.log(`[REDIS] Server version ${version}`);
      }
    } catch {
      // Purely informational; never let it affect startup.
    }
  }

  private markUnavailable(): void {
    if (this.unavailableSince === null) this.unavailableSince = Date.now();
  }

  private logConnectionError(err: Error): void {
    const now = Date.now();
    if (now - this.lastErrorLoggedAt < RedisService.ERROR_LOG_INTERVAL_MS) {
      this.suppressedErrorCount += 1;
      return;
    }
    const suppressed =
      this.suppressedErrorCount > 0
        ? ` (${this.suppressedErrorCount} similar errors suppressed in the last ${
            RedisService.ERROR_LOG_INTERVAL_MS / 1000
          }s)`
        : '';
    this.lastErrorLoggedAt = now;
    this.suppressedErrorCount = 0;
    this.logger.error(`[REDIS] Connection error: ${err.message}${suppressed}`);
  }

  /**
   * Bound any promise.
   *
   * ioredis has its own `commandTimeout`, and this wraps it anyway: the option
   * covers commands, not `connect()` or `quit()`, and a client stuck in a
   * connecting state would otherwise have no ceiling at all. One helper, so
   * every await in this file is provably finite.
   */
  private async withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([
        promise,
        new Promise<never>((_, reject) => {
          timer = setTimeout(
            () => reject(new Error(`[REDIS] ${label} timed out after ${ms}ms`)),
            ms,
          );
          timer.unref?.();
        }),
      ]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  }
}

/** Outcome of a limiter script. See redis.scripts.ts for the field contract. */
export interface ScriptResult {
  allowed: boolean;
  limit: number;
  remaining: number;
  retryAfterMs: number;
}

/** Raised when a command is attempted against a connection that is not ready. */
export class RedisUnavailableError extends Error {
  constructor(readonly connectionStatus: string) {
    super(`[REDIS] unavailable (status=${connectionStatus})`);
    this.name = 'RedisUnavailableError';
  }
}
