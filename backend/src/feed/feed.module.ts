import { Module } from '@nestjs/common';
import { FeedController } from './feed.controller';
import { FeedService } from './feed.service';
import { FeedSettingsService } from './feed-settings.service';
import { ViewerContextService } from './viewer-context.service';
import { FeedRepository } from './feed.repository';

/**
 * Discover recommendation engine.
 *
 * A leaf module: it imports nothing (SupabaseModule is @Global) and nothing
 * imports it. The ranking model itself lives in `ranking/`, which has no Nest
 * dependency at all and is unit-tested without a database.
 *
 * `FeedSettingsService` is exported so future admin tooling can invalidate the
 * weight cache after an edit.
 */
@Module({
  controllers: [FeedController],
  providers: [FeedService, FeedSettingsService, ViewerContextService, FeedRepository],
  exports: [FeedSettingsService, FeedService],
})
export class FeedModule {}
