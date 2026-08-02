import { Module } from '@nestjs/common';
import { EventProcessorService } from './event-processor.service';
import { EventsAdminController } from './events-admin.controller';
import { EventsHealthController } from './events-health.controller';
import { EventsModule } from './events.module';
import { SupabaseModule } from '../supabase/supabase.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { MpesaModule } from '../mpesa/mpesa.module';
import { ReputationModule } from '../reputation/reputation.module';
// Supplies AdminAuthGuard for EventsAdminController, which until now had no
// guard at all — see the comment at the top of events-admin.controller.ts.
import { AdminAuthModule } from '../admin/auth/admin-auth.module';

/**
 * Standalone module for event processing + observability.
 * Registered ONLY in AppModule — never imported by feature modules.
 *
 * Provides:
 *   EventProcessorService — 60s retry loop, handler dispatch
 *   GET  /health/events   — processor liveness + queue depth
 *   GET  /admin/events    — list / filter events
 *   GET  /admin/events/:id
 *   GET  /admin/events/dead-letter
 *   POST /admin/events/replay — manual event replay
 */
@Module({
  imports: [
    EventsModule,
    SupabaseModule,
    NotificationsModule,
    MpesaModule,
    ReputationModule,
    AdminAuthModule,
  ],
  providers: [EventProcessorService],
  controllers: [EventsAdminController, EventsHealthController],
  exports: [EventProcessorService],
})
export class EventProcessorModule {}
