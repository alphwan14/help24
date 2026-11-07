import { Module } from '@nestjs/common';
import { AdminAuthModule } from '../admin/auth/admin-auth.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { VerificationsAdminController } from './verifications-admin.controller';
import { VerificationsService } from './verifications.service';
import { VerificationsSweepService } from './verifications-sweep.service';

/**
 * Provider vetting: the admin review API and the sweep that hides expired
 * listings and deletes documents. Members submit straight to the database
 * (submit_provider_verification, migration 135), the same way they post.
 */
@Module({
  imports: [AdminAuthModule, NotificationsModule],
  controllers: [VerificationsAdminController],
  providers: [VerificationsService, VerificationsSweepService],
})
export class VerificationsModule {}
