import { MiddlewareConsumer, Module, NestModule } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { configuration } from './config/configuration';
import { SupabaseModule } from './supabase/supabase.module';
import { TransactionsModule } from './transactions/transactions.module';
import { ProvidersModule } from './providers/providers.module';
import { NotificationsModule } from './notifications/notifications.module';
import { EventsModule } from './events/events.module';
import { EventProcessorModule } from './events/event-processor.module';
import { MpesaModule } from './mpesa/mpesa.module';
import { JobsModule } from './jobs/jobs.module';
import { AdminModule } from './admin/admin.module';
import { ReputationModule } from './reputation/reputation.module';
import { ReviewsModule } from './reviews/reviews.module';
import { PromotionsModule } from './promotions/promotions.module';
import { RoutesModule } from './routes/routes.module';
import { FeedModule } from './feed/feed.module';
import { AppConfigModule } from './app-config/app-config.module';
import { DevModule } from './dev/dev.module';

// ── Production infrastructure (Phase 1) ──────────────────────────────────────
import { LoggingModule } from './common/logging/logging.module';
import { AccessLogMiddleware } from './common/logging/access-log.middleware';
import { RequestContextMiddleware } from './common/request-context/request-context.middleware';
import { IdentityModule } from './common/identity/identity.module';
import { IdentityMiddleware } from './common/identity/identity.middleware';
import { RateLimitModule } from './common/rate-limit/rate-limit.module';
import { AuthModule } from './common/auth/auth.module';
import { HealthModule } from './health/health.module';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      load: [configuration],
    }),

    // ── Infrastructure first ───────────────────────────────────────────────
    // Ordered ahead of the feature modules so that anything they log during
    // construction is already going through the structured writer.
    //
    // LoggingModule   the single StructuredLogger instance (global).
    // RateLimitModule registers a global APP_GUARD; imports RedisModule.
    // AuthModule      registers a global APP_GUARD + the token verifier (global).
    // IdentityModule  the middleware that resolves identity; needs AuthModule.
    // HealthModule    /health + the dependency probes; imports RedisModule.
    //
    // ⚠️ TWO ORDERING CONSTRAINTS, BOTH LOAD-BEARING:
    //
    //   RateLimitModule BEFORE AuthModule. Multiple APP_GUARD providers run in
    //   registration order, and rate limiting must come first — a flood of
    //   unauthenticated requests should be absorbed by the cheap counter check,
    //   not by identity handling. It is the same reasoning that already puts
    //   the rate-limit guard ahead of AdminAuthGuard.
    //
    //   AuthModule BEFORE IdentityModule. IdentityMiddleware injects
    //   TokenVerifierService, and middleware resolves its dependencies from
    //   AppModule's injector — so the provider has to exist by the time this
    //   list reaches IdentityModule.
    LoggingModule,
    RateLimitModule,
    AuthModule,
    IdentityModule,
    HealthModule,

    SupabaseModule,
    TransactionsModule,
    ProvidersModule,
    NotificationsModule,
    // EventsModule provides EventsService to feature modules.
    EventsModule,
    // Feature modules (import EventsModule for EventsService).
    MpesaModule,
    JobsModule,
    AdminModule,
    // Reputation engine: provider_reputation reads + recompute (server-authoritative).
    ReputationModule,
    // Review submission engine (eligibility-gated; recomputes reputation).
    ReviewsModule,
    // Business Promotion ("Promote Business"): campaigns, packages, M-Pesa
    // purchase, placement serving, analytics, moderation.
    PromotionsModule,
    // Discover recommendation engine: signal-aware candidate retrieval,
    // modular scoring, diversity/anti-spam composition, behavioural ingest.
    // The client falls back to its direct Supabase read if this is down.
    FeedModule,
    // Journey routing (Phase 3): Google Routes proxy for ETA, remaining
    // distance and polyline. Keeps the billable key off the device.
    RoutesModule,
    // The client configuration plane: kill switches, maintenance mode, the
    // minimum-version gate and the client tunables that previously required a
    // Play release. A leaf — nothing imports it. Serves compiled defaults when
    // `app_settings` is absent, so it is safe ahead of its own migration.
    AppConfigModule,
    // EventProcessorModule is registered last: it imports MpesaModule + EventsModule.
    // Nothing imports EventProcessorModule — it is a leaf that starts the retry loop.
    EventProcessorModule,
    // DevModule is a test harness leaf — all routes return 403 in production.
    DevModule,
  ],
})
export class AppModule implements NestModule {
  /**
   * The middleware chain, in the order it runs.
   *
   * ORDER IS LOAD-BEARING — each entry depends on the one before it:
   *
   *   1. RequestContextMiddleware
   *      Opens the AsyncLocalStorage scope and sets X-Request-Id. Must be
   *      first: nothing downstream can annotate or read a context that does
   *      not exist yet, and an error thrown before this point would produce a
   *      response with no correlation ID at all.
   *
   *   2. AccessLogMiddleware
   *      Registers the `finish`/`close` listener that emits the access log.
   *      Must come after (1) so the line carries a request ID, and BEFORE (3)
   *      so its listener is attached even if identity resolution throws — a
   *      request must never escape the log.
   *
   *   3. IdentityMiddleware
   *      Verifies a Firebase token if one is present and annotates the
   *      context. Runs last because it is the only one that can be slow (a
   *      token verification), and because everything before it must work
   *      whether or not it succeeds.
   *
   * Rate limiting is NOT here: it is a guard, because only a guard runs after
   * routing and can therefore read the `@RateLimit` decorator on the handler
   * it protects. See rate-limit.guard.ts.
   */
  configure(consumer: MiddlewareConsumer): void {
    consumer
      .apply(RequestContextMiddleware, AccessLogMiddleware, IdentityMiddleware)
      // Every route, including ones that will 404 — those are exactly the
      // requests worth logging when a client is calling the wrong path.
      .forRoutes('*');
  }
}
