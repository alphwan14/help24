import { Module } from '@nestjs/common';
import { JobsService } from './jobs.service';
import { ServiceRecordsService } from './service-records.service';
import { CompletionAutoApprovalService } from './completion-auto-approval.service';
import { JobsController } from './jobs.controller';
import { SupabaseModule } from '../supabase/supabase.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { EventsModule } from '../events/events.module';

// MpesaModule removed — jobs.service.ts no longer calls releasePayout() directly.
// The payment.payout_requested event is handled by EventProcessorService.

@Module({
  imports: [SupabaseModule, NotificationsModule, EventsModule],
  controllers: [JobsController],
  // ServiceRecordsService is a READ layer over the same tables JobsService
  // owns. It is registered here rather than in a module of its own because a
  // service record is not a new entity — it is the existing job, read back.
  // CompletionAutoApprovalService is the review-window sweep (migration 134):
  // it approves through JobsService.approveCompletion, so it lives beside it.
  providers: [JobsService, ServiceRecordsService, CompletionAutoApprovalService],
  // The dashboard's payment page approves through the same transition
  // (admin/payments, "Approve completion now").
  exports: [JobsService],
})
export class JobsModule {}
