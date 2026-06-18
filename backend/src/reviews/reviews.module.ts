import { Module } from '@nestjs/common';
import { SupabaseModule } from '../supabase/supabase.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { ReputationModule } from '../reputation/reputation.module';
import { ReviewsService } from './reviews.service';
import { ReviewsController } from './reviews.controller';

/**
 * Review submission engine (Phase 3.2D). Creates eligibility-gated reviews,
 * recomputes provider reputation immediately, and notifies the provider.
 */
@Module({
  imports: [SupabaseModule, NotificationsModule, ReputationModule],
  providers: [ReviewsService],
  controllers: [ReviewsController],
})
export class ReviewsModule {}
