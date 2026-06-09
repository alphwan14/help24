import { Module } from '@nestjs/common';
import { NotificationsService } from './notifications.service';
import { FirebaseAdminModule } from './firebase-admin.module';
import { SupabaseModule } from '../supabase/supabase.module';

@Module({
  imports:   [SupabaseModule, FirebaseAdminModule],
  providers: [NotificationsService],
  exports:   [NotificationsService],
})
export class NotificationsModule {}
