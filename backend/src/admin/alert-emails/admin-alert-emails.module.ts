import { Module } from '@nestjs/common';
import { AdminAuthModule } from '../auth/admin-auth.module';
import { AdminAlertsModule } from '../alerts/admin-alerts.module';
import { SupportModule } from '../../support/support.module';
import { AdminAlertEmailsController } from './admin-alert-emails.controller';
import { AdminAlertEmailsService } from './admin-alert-emails.service';

/**
 * Email alerts for admins (migration 141): reads the alert list
 * (AdminAlertsModule) and sends through the support mailer (SupportModule,
 * Resend). Nothing imports this module.
 */
@Module({
  imports: [AdminAuthModule, AdminAlertsModule, SupportModule],
  controllers: [AdminAlertEmailsController],
  providers: [AdminAlertEmailsService],
})
export class AdminAlertEmailsModule {}
