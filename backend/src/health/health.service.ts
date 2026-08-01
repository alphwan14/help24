import {
  Injectable,
  Logger,
  OnApplicationBootstrap,
  OnModuleDestroy,
} from '@nestjs/common';
import { PeriodicTask } from '../common/periodic-task';
import { RedisService } from '../redis/redis.service';
import { SupabaseService } from '../supabase/supabase.service';
import { FirebaseAdminService } from '../notifications/firebase-admin.service';
import {
  DependencyHealth,
  DependencyStatus,
  LATENCY_BUDGET_MS,
  PROBE_TIMEOUT_MS,
} from './health.types';

/**
 * Dependency probes, and the snapshot that keeps the liveness endpoint cheap.
 *
 * THE CONSTRAINT THAT SHAPED THIS DESIGN
 * --------------------------------------
 * `GET /health` is not only an orchestrator's liveness check. The Flutter app
 * uses it as its CONNECTIVITY PROBE: every device polls it, no more often than
 * every ten seconds, with a five-second timeout, and treats a failure as
 * evidence that the phone is offline (see ConnectivityProvider). Two hard
 * consequences follow:
 *
 *   1. It must be O(1) and fast. At a few thousand users that is hundreds of
 *      requests a minute; probing Supabase inline on each would turn the
 *      health check into a load generator against the database it is meant to
 *      be watching.
 *
 *   2. It must not go slow when a dependency does. If Supabase hangs and
 *      /health waits for it, the response exceeds the app's five-second
 *      timeout and every device in the country simultaneously decides it has
 *      no internet — a total, self-inflicted outage of the app's UI caused by
 *      a database that was merely slow.
 *
 * So /health NEVER probes inline. A background task refreshes a snapshot every
 * fifteen seconds and the endpoint returns whatever the snapshot says, which
 * makes its latency independent of every dependency's. The deep endpoints
 * (/health/database, /health/redis, /health/firebase) DO probe live, because
 * they are for operators and monitors, are rate-limited, and are allowed to
 * take as long as the dependency does.
 *
 * WHY PeriodicTask
 * ----------------
 * It already exists in this codebase for the three background sweeps, and it
 * already solves the two problems a naive `setInterval` has here: it skips a
 * tick while the previous one is still running (a wedged Supabase must not
 * stack probes), and it drains in flight work on shutdown.
 */
@Injectable()
export class HealthService implements OnApplicationBootstrap, OnModuleDestroy {
  private readonly logger = new Logger(HealthService.name);
  private readonly refresh = new PeriodicTask('HEALTH][SNAPSHOT', this.logger);

  /**
   * 15s: fast enough that a dependency failure shows up in the aggregate
   * within one monitoring interval, slow enough that the probes themselves are
   * negligible load (4 Supabase reads per minute).
   */
  private static readonly SNAPSHOT_INTERVAL_MS = 15_000;

  private snapshot: DependencyHealth[] = [];
  private snapshotAt: string | null = null;

  /**
   * In-flight probes, keyed by dependency.
   *
   * Single-flight: fifty monitors hitting /health/database at once produce ONE
   * query, not fifty. Without this, the health endpoint becomes an
   * amplification vector — the cheapest way to put load on the database is to
   * ask repeatedly whether the database is under load.
   */
  private readonly inFlight = new Map<string, Promise<DependencyHealth>>();

  private readonly startedAt = Date.now();

  constructor(
    private readonly supabase: SupabaseService,
    private readonly redis: RedisService,
    private readonly firebase: FirebaseAdminService,
  ) {}

  async onApplicationBootstrap(): Promise<void> {
    // Warm the snapshot before the first request can ask for it, so /health
    // never has to answer "unknown" and never has to block to avoid doing so.
    await this.refreshSnapshot();
    this.refresh.start(() => this.refreshSnapshot(), HealthService.SNAPSHOT_INTERVAL_MS);
  }

  async onModuleDestroy(): Promise<void> {
    await this.refresh.stop();
  }

  // ── Aggregate (cheap, snapshot-backed) ─────────────────────────────────────

  /** The last known state of every dependency. Never performs I/O. */
  getSnapshot(): { dependencies: DependencyHealth[]; snapshotAt: string | null } {
    return { dependencies: this.snapshot, snapshotAt: this.snapshotAt };
  }

  get uptimeSeconds(): number {
    return Math.round((Date.now() - this.startedAt) / 1000);
  }

  private async refreshSnapshot(): Promise<void> {
    // Probed in parallel: three sequential probes would make the refresh as
    // slow as their sum, and they are entirely independent.
    this.snapshot = await Promise.all([
      this.checkDatabase(),
      this.checkRedis(),
      this.checkFirebase(),
    ]);
    this.snapshotAt = new Date().toISOString();
  }

  // ── Live probes (used by the deep endpoints) ───────────────────────────────

  checkDatabase(): Promise<DependencyHealth> {
    return this.singleFlight('database', async () => {
      const startedAt = Date.now();
      try {
        // The lightest read that proves the whole path works: network reach,
        // service-role credential accepted, schema present, PostgREST healthy.
        // `limit(1)` on an indexed primary key is an index scan returning at
        // most one row — a count would be a table scan and a health check must
        // never be the most expensive query on the box.
        const { error } = await this.supabase.client
          .from(healthProbeTable())
          .select('id')
          .limit(1)
          // A real abort, not just an abandoned promise: without it a hung
          // request would keep a socket and a Postgres connection occupied
          // long after this probe gave up on it.
          .abortSignal(AbortSignal.timeout(PROBE_TIMEOUT_MS.database));

        const latencyMs = Date.now() - startedAt;

        if (error) {
          return this.result('database', 'unavailable', latencyMs, `query failed: ${error.message}`, {
            table: healthProbeTable(),
          });
        }

        return this.result(
          'database',
          latencyMs > LATENCY_BUDGET_MS.database ? 'degraded' : 'healthy',
          latencyMs,
          latencyMs > LATENCY_BUDGET_MS.database
            ? `responded in ${latencyMs}ms, above the ${LATENCY_BUDGET_MS.database}ms budget`
            : undefined,
          { table: healthProbeTable() },
        );
      } catch (err) {
        return this.result(
          'database',
          'unavailable',
          Date.now() - startedAt,
          err instanceof Error ? err.message : String(err),
        );
      }
    });
  }

  checkRedis(): Promise<DependencyHealth> {
    return this.singleFlight('redis', async () => {
      if (!this.redis.isConfigured) {
        // Not an error. The system is designed to run without Redis, with
        // per-instance rate limits — a real reduction in guarantee, which is
        // what "degraded" is for. Reporting it as healthy would hide a
        // production misconfiguration; reporting it as unavailable would page
        // someone for an intended local-development state.
        return this.result(
          'redis',
          'degraded',
          null,
          'REDIS_URL is not set — rate limits are enforced per instance and do not ' +
            'hold across replicas.',
          { configured: false, status: this.redis.status },
        );
      }

      const ping = await this.redis.ping();
      const meta = {
        configured: true,
        status: this.redis.status,
        url: this.redis.safeUrl,
        degradedForMs: this.redis.degradedForMs ?? undefined,
      };

      if (!ping.ok) {
        return this.result('redis', 'unavailable', ping.latencyMs, ping.detail ?? 'PING failed', meta);
      }

      const slow = (ping.latencyMs ?? 0) > LATENCY_BUDGET_MS.redis;
      return this.result(
        'redis',
        slow ? 'degraded' : 'healthy',
        ping.latencyMs,
        slow
          ? `PING took ${ping.latencyMs}ms, above the ${LATENCY_BUDGET_MS.redis}ms budget — ` +
            `the rate limiter adds this to every request.`
          : undefined,
        meta,
      );
    });
  }

  checkFirebase(): Promise<DependencyHealth> {
    return this.singleFlight('firebase', async () => {
      const app = this.firebase.app;
      if (!app) {
        return this.result(
          'firebase',
          'unavailable',
          null,
          'Firebase Admin is not initialized — push notifications cannot be sent. ' +
            'Set FIREBASE_PROJECT_ID, FIREBASE_CLIENT_EMAIL and FIREBASE_PRIVATE_KEY.',
          { initialized: false },
        );
      }

      const startedAt = Date.now();
      const meta = { initialized: true, projectId: app.options.projectId };

      try {
        // "Verify initialization" taken seriously. An initialized App object
        // proves only that three environment variables parsed — a malformed
        // private key, a revoked service account or a disabled project all
        // produce a perfectly healthy-looking App that fails on the first push.
        // Minting an access token exercises the credential end to end, which
        // is the difference between checking configuration and checking the
        // dependency. The SDK caches the token for about an hour, so the
        // network cost is paid roughly once per hour, not per probe.
        const credential = app.options.credential;
        if (!credential) {
          return this.result('firebase', 'degraded', null, 'App has no credential attached.', meta);
        }

        await withTimeout(
          credential.getAccessToken(),
          PROBE_TIMEOUT_MS.firebase,
          'firebase access token',
        );

        const latencyMs = Date.now() - startedAt;
        return this.result(
          'firebase',
          latencyMs > LATENCY_BUDGET_MS.firebase ? 'degraded' : 'healthy',
          latencyMs,
          undefined,
          meta,
        );
      } catch (err) {
        // Initialized but the credential will not mint a token: pushes are
        // broken, yet the rest of the API is entirely unaffected. Degraded,
        // not unavailable — and the detail says exactly what to look at.
        return this.result(
          'firebase',
          'degraded',
          Date.now() - startedAt,
          `credential could not obtain an access token: ${
            err instanceof Error ? err.message : String(err)
          }`,
          meta,
        );
      }
    });
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  private singleFlight(
    name: string,
    probe: () => Promise<DependencyHealth>,
  ): Promise<DependencyHealth> {
    const existing = this.inFlight.get(name);
    if (existing) return existing;

    const promise = probe().finally(() => this.inFlight.delete(name));
    this.inFlight.set(name, promise);
    return promise;
  }

  private result(
    name: string,
    status: DependencyStatus,
    latencyMs: number | null,
    detail?: string,
    meta?: Record<string, unknown>,
  ): DependencyHealth {
    return { name, status, latencyMs, detail, meta, checkedAt: new Date().toISOString() };
  }
}

/**
 * The table the database probe reads.
 *
 * Configurable so the probe does not become a reason a table can never be
 * renamed. `posts` is the default because it is the busiest table in the
 * system: if it is readable, the parts of Supabase this backend depends on are
 * working.
 */
function healthProbeTable(): string {
  return process.env.HEALTH_DB_TABLE?.trim() || 'posts';
}

async function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms);
        timer.unref?.();
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}
