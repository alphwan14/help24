import { Module } from '@nestjs/common';
import { AdminAuthModule } from '../admin/auth/admin-auth.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { SupportAdminController } from './support-admin.controller';
import { SupportAppController } from './support-app.controller';
import { SupportInboundController } from './support-inbound.controller';
import { SupportMailerService } from './support-mailer.service';
import { SupportService } from './support.service';

/**
 * The support Inbox (migration 138): support@, info@ and security@ mail in
 * through the Cloudflare Email Worker, members' messages from the app
 * (Message Help24, migration 142), staff answers out by email through Resend
 * or into the app with a notification (NotificationsModule). Imports
 * AdminAuthModule for the guard only; reads and writes through the global
 * Supabase client. Exports its mailer, which the admin alert emails
 * (AdminAlertEmailsModule) send through.
 */
@Module({
  imports: [AdminAuthModule, NotificationsModule],
  controllers: [SupportAdminController, SupportInboundController, SupportAppController],
  providers: [SupportService, SupportMailerService],
  exports: [SupportMailerService],
})
export class SupportModule {}
