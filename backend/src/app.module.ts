import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { configuration } from './config/configuration';
import { SupabaseModule } from './supabase/supabase.module';
import { TransactionsModule } from './transactions/transactions.module';
import { ProvidersModule } from './providers/providers.module';
import { NotificationsModule } from './notifications/notifications.module';
import { EventsModule } from './events/events.module';
import { EventProcessorModule } from './events/event-processor.module';
import { MpesaModule } from './mpesa/mpesa.module';
import { JobsModule } from './jobs/jobs.module';
import { AdminModule } from './admin/admin.module';
import { HealthController, RootController } from './health.controller';
import { DevModule } from './dev/dev.module';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      load: [configuration],
    }),
    SupabaseModule,
    TransactionsModule,
    ProvidersModule,
    NotificationsModule,
    // EventsModule provides EventsService to feature modules.
    EventsModule,
    // Feature modules (import EventsModule for EventsService).
    MpesaModule,
    JobsModule,
    AdminModule,
    // EventProcessorModule is registered last: it imports MpesaModule + EventsModule.
    // Nothing imports EventProcessorModule — it is a leaf that starts the retry loop.
    EventProcessorModule,
    // DevModule is a test harness leaf — all routes return 403 in production.
    DevModule,
  ],
  controllers: [RootController, HealthController],
})
export class AppModule {}
