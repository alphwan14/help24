import { Module } from '@nestjs/common';
import { AdminAuthModule } from '../admin/auth/admin-auth.module';
import { SupportAdminController } from './support-admin.controller';
import { SupportInboundController } from './support-inbound.controller';
import { SupportMailerService } from './support-mailer.service';
import { SupportService } from './support.service';

/**
 * The support Inbox (migration 138): support@ and info@ mail in through the
 * Cloudflare Email Worker, staff replies out by email through Resend. Imports
 * AdminAuthModule for the guard only; reads and writes through the global
 * Supabase client. A leaf: nothing imports it.
 */
@Module({
  imports: [AdminAuthModule],
  controllers: [SupportAdminController, SupportInboundController],
  providers: [SupportService, SupportMailerService],
})
export class SupportModule {}
