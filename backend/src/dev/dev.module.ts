import { Module } from '@nestjs/common';
import { DevService } from './dev.service';
import { DevController } from './dev.controller';
import { SupabaseModule } from '../supabase/supabase.module';
import { EventsModule } from '../events/events.module';
import { EventProcessorModule } from '../events/event-processor.module';
import { FirebaseAdminModule } from '../notifications/firebase-admin.module';

/**
 * Dev/test harness module.
 * Registered in AppModule after EventProcessorModule.
 * All routes return 403 ForbiddenException when MPESA_ENV=production.
 */
@Module({
  imports: [SupabaseModule, EventsModule, EventProcessorModule, FirebaseAdminModule],
  providers: [DevService],
  controllers: [DevController],
})
export class DevModule {}
