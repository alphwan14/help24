import { Module } from '@nestjs/common';
import { AdminService } from './admin.service';
import { AdminController } from './admin.controller';
import { SupabaseModule } from '../supabase/supabase.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { MpesaModule } from '../mpesa/mpesa.module';
import { EventsModule } from '../events/events.module';

@Module({
  imports: [SupabaseModule, NotificationsModule, MpesaModule, EventsModule],
  controllers: [AdminController],
  providers: [AdminService],
})
export class AdminModule {}
