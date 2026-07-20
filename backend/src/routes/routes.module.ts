import { Module } from '@nestjs/common';
import { RoutesController } from './routes.controller';
import { RoutesService } from './routes.service';

/**
 * Journey routing (Phase 3). Self-contained leaf: no other module depends on
 * it, and it degrades to "unavailable" when GOOGLE_ROUTES_API_KEY is unset.
 */
@Module({
  controllers: [RoutesController],
  providers: [RoutesService],
  exports: [RoutesService],
})
export class RoutesModule {}
