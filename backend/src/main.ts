import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { ValidationPipe } from '@nestjs/common';
import { AppModule } from './app.module';
import { AllExceptionsFilter } from './common/all-exceptions.filter';
import { EventProcessorService } from './events/event-processor.service';
import { JobsService } from './jobs/jobs.service';
import { DevService } from './dev/dev.service';
import { CampaignsService } from './promotions/campaigns.service';

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create(AppModule);

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

  // Bind 0.0.0.0 so the container/host (Render) can route external traffic.
  const port = process.env.PORT || 3000;
  await app.listen(port, '0.0.0.0');
  console.log(`[Help24] Backend running on 0.0.0.0:${port}`);

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
      console.log(`[Help24][ROUTES] ✓ ${label} loaded — ${routes}`);
    } catch {
      console.error(`[Help24][ROUTES] ✗ ${label} FAILED TO LOAD — ${routes} will 404`);
      allOk = false;
    }
  }

  if (allOk) {
    console.log('[Help24][ROUTES] All observability + dev modules confirmed active.');
  } else {
    console.error('[Help24][ROUTES] One or more modules failed — check NestJS DI logs above.');
  }
}

bootstrap().catch((err: Error) => {
  console.error('[Help24] Startup failed:', err.message);
  process.exit(1);
});
