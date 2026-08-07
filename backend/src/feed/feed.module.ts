import { Module } from '@nestjs/common';
import { AdminAuthModule } from '../admin/auth/admin-auth.module';
import { FeedController } from './feed.controller';
import { FeedSettingsAdminController } from './feed-settings-admin.controller';
import { FeedService } from './feed.service';
import { FeedSettingsService } from './feed-settings.service';
import { ViewerContextService } from './viewer-context.service';
import { FeedRepository } from './feed.repository';

/**
 * Discover recommendation engine.
 *
 * Imports only AdminAuthModule, for the guard on the ranking write surface
 * (SupabaseModule is @Global); nothing imports this module. The ranking model
 * itself lives in `ranking/`, which has no Nest dependency at all and is
 * unit-tested without a database.
 *
 * AdminAuthModule is not optional decoration: `AdminAuthGuard` injects
 * `AdminAuthService`, and without this import the application fails to boot
 * with "Nest can't resolve dependencies of the AdminAuthGuard". Unit tests do
 * NOT catch it — they construct the controller directly and never exercise the
 * injector — so this line is only ever validated by actually starting the app.
 *
 * `FeedSettingsService` is exported so future admin tooling can invalidate the
 * weight cache after an edit. `FeedSettingsAdminController` is that tooling —
 * it lives here rather than under `admin/` so the ranking write path sits
 * beside the reader it invalidates.
 */
@Module({
  imports: [AdminAuthModule],
  controllers: [FeedController, FeedSettingsAdminController],
  providers: [FeedService, FeedSettingsService, ViewerContextService, FeedRepository],
  exports: [FeedSettingsService, FeedService],
})
export class FeedModule {}
