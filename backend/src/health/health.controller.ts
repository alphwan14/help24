import { Controller, Get, HttpStatus, Res, UseGuards } from '@nestjs/common';
import { Response } from 'express';
import { RateLimit, SkipRateLimit } from '../common/rate-limit/rate-limit.decorator';
import { AdminAuth, Public } from '../common/auth/auth.decorator';
import { AdminAuthGuard } from '../admin/auth/admin-auth.guard';
import { RequestContextStore } from '../common/request-context/request-context';
import { HealthService } from './health.service';
import { DependencyHealth, DependencyStatus } from './health.types';

/**
 * Health endpoints.
 *
 * WHY /health NEVER RETURNS 503
 * -----------------------------
 * Two different questions get asked of a health endpoint and they want
 * opposite answers:
 *
 *   Liveness   "is this process wedged — should I restart it?"
 *   Dependency "is Supabase reachable — should someone be paged?"
 *
 * Conflating them is a well-known way to turn a small incident into a large
 * one. If /health returned 503 while Supabase was slow, Docker's HEALTHCHECK
 * would mark the container unhealthy and Render would pull it from rotation —
 * restarting a perfectly good process, repeatedly, for a fault that a restart
 * cannot fix. Worse here than in most systems, because the Flutter app polls
 * this same endpoint as its connectivity probe: a 503 makes every device
 * display "you are offline" while the phone's connection is fine.
 *
 * So /health answers ONLY the liveness question, and answers it 200 whenever
 * the process can serve a request. The dependency question is answered in the
 * body (`status: ok | degraded`) and, in detail, by the three endpoints below,
 * which DO return 503 — because their audience is a monitor and a human, not
 * a supervisor with a restart button.
 *
 * WHAT THE PUBLIC SEES (2026-10-30)
 * ---------------------------------
 * /health and / are public and say only ok/degraded. Which dependencies the
 * service has, how long it has been up and what a probe found are Help24's
 * business, not the internet's: that detail (/health/detail) and the three
 * deep probes need a signed-in admin. Nothing polls them unattended —
 * Docker, Render and the app read only the status code of /health.
 *
 * BACKWARDS COMPATIBILITY
 * -----------------------
 * The previous response was `{ status: 'ok', service: 'help24-backend',
 * timestamp }`. All three fields are preserved with identical meaning, and
 * `status` is still the string `'ok'` when everything is healthy. Existing
 * consumers — the Docker HEALTHCHECK and the app's ConnectivityProvider, which
 * only checks for HTTP 200 — are unaffected.
 */
// A liveness check that requires credentials is not a liveness check: /health
// is polled by Docker's HEALTHCHECK, by Render and by every device in the field
// as its connectivity probe, none of which hold a token. So it stays public —
// and says nothing beyond ok/degraded. Everything deeper needs an admin.
@Controller('health')
@Public('Liveness for orchestrators and the app connectivity check: ok/degraded only.')
export class HealthController {
  constructor(private readonly health: HealthService) {}

  /**
   * Liveness. Cheap, constant-time, never blocks on a dependency.
   *
   * SkipRateLimit is justified here and nowhere else: a rate-limit check costs
   * a Redis round trip, and this response costs a property read. Limiting it
   * would make the check more expensive than the thing it protects — and would
   * risk 429ing the connectivity probe of every device behind one carrier NAT,
   * which the app would render as "you are offline". The endpoint performs no
   * I/O and returns a fixed-size body, so it is not a useful amplification
   * target.
   */
  @Get()
  @SkipRateLimit()
  liveness() {
    const { dependencies, snapshotAt } = this.health.getSnapshot();

    return {
      // 'ok' when every dependency is healthy — byte-identical to the previous
      // implementation's response for the healthy case.
      status: worstOf(dependencies) === 'healthy' ? 'ok' : 'degraded',
      service: 'help24-backend',
      timestamp: new Date().toISOString(),
    };
  }

  /**
   * What /health used to add for everyone: per-dependency status, uptime and
   * the snapshot's age (a stale one means the background refresh stopped —
   * a "this process is unwell" signal no probe would reveal). Admins only.
   */
  @Get('detail')
  @RateLimit('health:deep')
  @UseGuards(AdminAuthGuard)
  @AdminAuth()
  detail() {
    const { dependencies, snapshotAt } = this.health.getSnapshot();
    return {
      status: worstOf(dependencies) === 'healthy' ? 'ok' : 'degraded',
      uptimeSeconds: this.health.uptimeSeconds,
      requestId: RequestContextStore.requestId(),
      dependencies: summarize(dependencies),
      dependenciesCheckedAt: snapshotAt,
    };
  }

  /**
   * Live probe: a real indexed read against Supabase.
   *
   * 200 when healthy or degraded, 503 when unavailable — see the class comment
   * for why the deep endpoints are allowed to fail loudly and /health is not.
   */
  @Get('database')
  @RateLimit('health:deep')
  @UseGuards(AdminAuthGuard)
  @AdminAuth()
  async database(@Res({ passthrough: true }) res: Response) {
    return respond(res, await this.health.checkDatabase());
  }

  /** Live probe: PING. */
  @Get('redis')
  @RateLimit('health:deep')
  @UseGuards(AdminAuthGuard)
  @AdminAuth()
  async redis(@Res({ passthrough: true }) res: Response) {
    return respond(res, await this.health.checkRedis());
  }

  /** Live probe: the service-account credential mints an access token. */
  @Get('firebase')
  @RateLimit('health:deep')
  @UseGuards(AdminAuthGuard)
  @AdminAuth()
  async firebase(@Res({ passthrough: true }) res: Response) {
    return respond(res, await this.health.checkFirebase());
  }
}

/**
 * `GET /` — unchanged in shape from the previous implementation.
 *
 * Kept because Render's default health check and assorted uptime monitors
 * point at the root. It is deliberately the plainest possible answer: no
 * dependency information, so it cannot become slow.
 */
@Controller()
@Public("Render's default health check and assorted uptime monitors point at the root.")
export class RootController {
  @Get()
  @SkipRateLimit()
  root() {
    return {
      status: 'ok',
      service: 'help24-backend',
      timestamp: new Date().toISOString(),
    };
  }
}

/**
 * The worst status present. `unavailable` beats `degraded` beats `healthy`,
 * so one broken dependency is never masked by two working ones.
 */
function worstOf(dependencies: DependencyHealth[]): DependencyStatus {
  if (dependencies.length === 0) return 'degraded'; // snapshot not warmed yet
  if (dependencies.some((d) => d.status === 'unavailable')) return 'unavailable';
  if (dependencies.some((d) => d.status === 'degraded')) return 'degraded';
  return 'healthy';
}

/** Compact per-dependency view for the aggregate response. */
function summarize(dependencies: DependencyHealth[]): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const dependency of dependencies) {
    out[dependency.name] = {
      status: dependency.status,
      latencyMs: dependency.latencyMs,
      ...(dependency.detail ? { detail: dependency.detail } : {}),
    };
  }
  return out;
}

/**
 * Set the status code from the dependency's health, then return the body.
 *
 * `passthrough: true` keeps Nest's serialization and the global exception
 * filter in play — using the raw response to `.json()` here would bypass both
 * and lose the request-id handling they perform.
 */
function respond(res: Response, health: DependencyHealth): DependencyHealth & { requestId?: string } {
  res.status(
    health.status === 'unavailable' ? HttpStatus.SERVICE_UNAVAILABLE : HttpStatus.OK,
  );
  return { ...health, requestId: RequestContextStore.requestId() };
}
