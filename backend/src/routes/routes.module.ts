import { Module } from '@nestjs/common';
import { RateLimitModule } from '../common/rate-limit/rate-limit.module';
import { RoutesController } from './routes.controller';
import { RoutesService } from './routes.service';

/**
 * Journey routing (Phase 3). Self-contained leaf: no other module depends on
 * it, and it degrades to "unavailable" when GOOGLE_ROUTES_API_KEY is unset.
 *
 * Imports RateLimitModule because this is the one place a limit is applied
 * INSIDE a service rather than by the global guard: only a cache miss reaches
 * Google and only a cache miss should consume budget, and the guard runs
 * before the handler can consult its cache. See routes.service.ts.
 */
@Module({
  imports: [RateLimitModule],
  controllers: [RoutesController],
  providers: [RoutesService],
  exports: [RoutesService],
})
export class RoutesModule {}
