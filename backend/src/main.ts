import { NestExpressApplication } from '@nestjs/platform-express';
import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { Logger, ValidationPipe } from '@nestjs/common';
import { AppModule } from './app.module';
import { AllExceptionsFilter } from './common/all-exceptions.filter';
import { StructuredLogger } from './common/logging/structured-logger.service';
import { RedisService } from './redis/redis.service';
import { EventProcessorService } from './events/event-processor.service';
import { JobsService } from './jobs/jobs.service';
import { DevService } from './dev/dev.service';
import { CampaignsService } from './promotions/campaigns.service';

async function bootstrap(): Promise<void> {
  // `bufferLogs` holds everything Nest emits while the container is being
  // built, so it can be replayed through StructuredLogger the moment that
  // provider is resolvable. Without it the first seconds of every boot — DI
  // errors and module-init failures among them — would use Nest's default
  // format and be missing from a structured log pipeline entirely.
  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    bufferLogs: true,
  });

  // One writer for the whole process: Nest's own output, every existing
  // `new Logger(X)` call site across the thirty-odd services, and the access
  // log all pass through this instance. See structured-logger.service.ts.
  app.useLogger(app.get(StructuredLogger));

  // Render terminates TLS at an edge proxy, so without this every request
  // reports the proxy's address as its client IP. Anything that reasons about
  // the caller — currently the Routes spend budget — would then see all users
  // as ONE caller and throttle them collectively. Trusting the proxy makes
  // req.ip the real client via X-Forwarded-For.
  app.set('trust proxy', 1);

  // CORS is environment-driven: set CORS_ORIGINS to a comma-separated allowlist
  // in production (e.g. https://help24-admin-dashboard.vercel.app). Unset → allow all (dev).
  const corsOrigins = process.env.CORS_ORIGINS?.split(',')
    .map((o) => o.trim())
    .filter(Boolean);
  app.enableCors({
    origin: corsOrigins && corsOrigins.length > 0 ? corsOrigins : '*',
  });

  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      forbidNonWhitelisted: true,
      transform: true,
    }),
  );

  app.useGlobalFilters(new AllExceptionsFilter());

  // Without this, Nest ignores SIGTERM and the process is simply killed — so
  // onModuleDestroy() never runs and the three background sweeps (event retry,
  // promotions lifecycle, dispute SLA) are terminated mid-tick.
  //
  // With it, SIGTERM closes the HTTP server and awaits every destroy hook.
  // Those hooks are async and drain the sweep in flight (see PeriodicTask),
  // which is the half that actually protects a payout retry or a dispute
  // escalation from being cut in two. Nest re-raises the original signal once
  // they resolve, so a lingering handle can never leave the process hanging —
  // and PeriodicTask bounds its own drain at 10s, well inside the 30s grace
  // period, so shutdown is predictable even when a sweep is wedged.
  //
  // This is how every orchestrator asks a process to stop: `docker stop` and
  // `docker compose down` send SIGTERM then SIGKILL after a grace period, and
  // Render does the same on redeploy. Correct in both, container or not.
  //
  // ⚠️ Only reaches Node if Node is the process that receives the signal. The
  // Dockerfile guarantees that (dumb-init as PID 1 + exec-form CMD). On Render,
  // the start command must be `node dist/main.js` — a shell-form wrapper eats
  // SIGTERM and none of this runs.
  //
  // Which is precisely why the signal is logged the instant it lands. Whether
  // SIGTERM arrives at all depends on deployment configuration nobody can see
  // from inside the code, and its absence is silent: the process just stops. A
  // line in the log turns "did shutdown work?" from a guess into a fact.
  //
  // `once`, and registered BEFORE enableShutdownHooks, for a reason that is easy
  // to get wrong. Nest's handler ends by re-raising the same signal to let the
  // DEFAULT action terminate the process — but Node only performs the default
  // action when no listener remains. A persistent listener here would swallow
  // that re-raise and hang the process until SIGKILL, turning an observability
  // aid into an outage. `once` removes itself after the first delivery, so the
  // re-raise finds nothing and terminates cleanly.
  for (const signal of ['SIGTERM', 'SIGINT'] as const) {
    process.once(signal, () => {
      new Logger('Shutdown').log(
        `[Help24][SHUTDOWN] ${signal} received — draining HTTP, background ` +
          `sweeps and the Redis connection (uptime=${Math.round(process.uptime())}s)`,
      );
    });
  }

  app.enableShutdownHooks();

  // Bind 0.0.0.0 so the container/host (Render) can route external traffic.
  const port = process.env.PORT || 3000;
  await app.listen(port, '0.0.0.0');

  // Boot output goes through the structured logger like everything else, so a
  // log pipeline sees one format from the first line. `console.log` here would
  // emit an unparseable record in the middle of a JSON stream.
  const logger = new Logger('Bootstrap');
  logger.log(`[Help24] Backend running on 0.0.0.0:${port}`);

  // ── Startup route verification ─────────────────────────────────────────────
  // Resolving each service proves the module loaded and its controller routes
  // are active. If app.get() throws, that module failed to initialize and all
  // its routes will 404.
  const checks: Array<{ label: string; routes: string; token: unknown }> = [
    {
      label: 'EventProcessorModule',
      routes: 'GET /health/events, GET /admin/events/*, POST /admin/events/replay',
      token: EventProcessorService,
    },
    {
      label: 'JobsModule',
      routes: 'POST /jobs/select-provider, POST /jobs/mark-complete, POST /jobs/approve, POST /jobs/notify-application',
      token: JobsService,
    },
    {
      label: 'DevModule',
      routes: 'POST /dev/reset-state, POST /dev/trigger-event',
      token: DevService,
    },
    {
      label: 'PromotionsModule',
      routes: 'GET /promotions/packages, GET /promotions/slots, POST /promotions/campaigns, GET /admin/promotions/campaigns',
      token: CampaignsService,
    },
  ];

  let allOk = true;
  for (const { label, routes, token } of checks) {
    try {
      app.get(token as Parameters<typeof app.get>[0]);
      logger.log(`[Help24][ROUTES] ✓ ${label} loaded — ${routes}`);
    } catch {
      logger.error(`[Help24][ROUTES] ✗ ${label} FAILED TO LOAD — ${routes} will 404`);
      allOk = false;
    }
  }

  if (allOk) {
    logger.log('[Help24][ROUTES] All observability + dev modules confirmed active.');
  } else {
    logger.error('[Help24][ROUTES] One or more modules failed — check NestJS DI logs above.');
  }

  reportInfrastructure(app.get(RedisService), logger);
}

/**
 * State-of-the-infrastructure banner, printed once per boot.
 *
 * This exists because the most dangerous configuration mistake this phase can
 * produce is SILENT: a deployment with no REDIS_URL works perfectly, serves
 * every request, and enforces rate limits that quietly do not hold across
 * replicas. Nothing fails, no endpoint errors, and the gap is invisible until
 * someone scales to two instances and wonders why limits stopped working.
 *
 * A boot log is where an operator looks first, so the degraded case is stated
 * there in the plainest terms available, alongside the exact variable to set.
 */
function reportInfrastructure(redis: RedisService, logger: Logger): void {
  const format = process.env.LOG_FORMAT ?? (process.env.NODE_ENV === 'production' ? 'json' : 'pretty');
  logger.log(
    `[Help24][INFRA] logging=${format} level=${process.env.LOG_LEVEL ?? 'log'} ` +
      `piiMasking=${process.env.LOG_MASK_PII !== 'false'} requestIds=on`,
  );

  if (!redis.isConfigured) {
    logger.warn(
      '[Help24][INFRA] ══════════════════════════════════════════════════════════\n' +
        '  RATE LIMITING IS DEGRADED — REDIS_URL is not set.\n' +
        '  Limits are enforced PER INSTANCE and do NOT hold across replicas.\n' +
        '  This is safe for local development and NOT safe for production.\n' +
        '  Fix: set REDIS_URL, then set REDIS_REQUIRED=true so a future\n' +
        '  misconfiguration fails the deploy instead of degrading silently.\n' +
        '  ══════════════════════════════════════════════════════════════════',
    );
    return;
  }

  logger.log(
    `[Help24][INFRA] Redis ${redis.status} — ${redis.safeUrl} ` +
      `keyPrefix="${redis.keyPrefix}" commandTimeout=${redis.commandTimeoutMs}ms ` +
      `required=${process.env.REDIS_REQUIRED === 'true'}`,
  );

  if (!redis.isAvailable) {
    logger.warn(
      '[Help24][INFRA] Redis is configured but NOT connected — rate limits are ' +
        'running on the per-instance fallback until it recovers. Check /health/redis.',
    );
  }
}

bootstrap().catch((err: Error) => {
  console.error('[Help24] Startup failed:', err.message);
  process.exit(1);
});
