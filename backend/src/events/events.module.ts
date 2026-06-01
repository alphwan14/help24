import { Module } from '@nestjs/common';
import { EventsService } from './events.service';
import { SupabaseModule } from '../supabase/supabase.module';

/**
 * Thin module — only EventsService (the DB write layer).
 * No dependency on MpesaModule or any other feature module.
 *
 * MpesaModule, JobsModule, AdminModule all import this module to get
 * EventsService without creating circular dependencies.
 */
@Module({
  imports: [SupabaseModule],
  providers: [EventsService],
  exports: [EventsService],
})
export class EventsModule {}
