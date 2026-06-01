import { Module } from '@nestjs/common';
import { JobsService } from './jobs.service';
import { JobsController } from './jobs.controller';
import { SupabaseModule } from '../supabase/supabase.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { EventsModule } from '../events/events.module';

// MpesaModule removed — jobs.service.ts no longer calls releasePayout() directly.
// The payment.payout_requested event is handled by EventProcessorService.

@Module({
  imports: [SupabaseModule, NotificationsModule, EventsModule],
  controllers: [JobsController],
  providers: [JobsService],
})
export class JobsModule {}
