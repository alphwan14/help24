import { Module } from '@nestjs/common';
import { NotificationsService } from './notifications.service';
import { NotificationsController } from './notifications.controller';
import { FirebaseAdminModule } from './firebase-admin.module';
import { SupabaseModule } from '../supabase/supabase.module';

@Module({
  imports:     [SupabaseModule, FirebaseAdminModule],
  providers:   [NotificationsService],
  controllers: [NotificationsController],
  exports:     [NotificationsService],
})
export class NotificationsModule {}
