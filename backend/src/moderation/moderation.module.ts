import { Module } from '@nestjs/common';
import { AdminAuthModule } from '../admin/auth/admin-auth.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { FirebaseAdminModule } from '../notifications/firebase-admin.module';
import { ModerationEnforcementModule } from './moderation-enforcement.module';
import { ReportsController } from './reports.controller';
import { ModerationAdminController } from './moderation-admin.controller';
import { ReportsService } from './reports.service';
import { ReportEvidenceService } from './report-evidence.service';
import { ModerationService } from './moderation.service';
import { InvestigationService } from './investigation.service';
import { ChatAttachmentLinksService } from './chat-attachment-links.service';

/**
 * Trust & Safety: reporting (users), investigation and moderation (admins).
 *
 * Everything that WRITES moderation state goes through the migration-115
 * database functions, which write the ledger in the same transaction. The
 * enforcement guard lives in ModerationEnforcementModule (see there for why).
 * Imports AdminAuthModule rather than AdminModule, which would drag in the
 * disputes and M-Pesa graph for nothing.
 */
@Module({
  imports: [ModerationEnforcementModule, AdminAuthModule, NotificationsModule, FirebaseAdminModule],
  controllers: [ReportsController, ModerationAdminController],
  providers: [ReportsService, ReportEvidenceService, ChatAttachmentLinksService, ModerationService, InvestigationService],
})
export class ModerationModule {}
