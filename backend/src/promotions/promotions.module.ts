import { Module } from '@nestjs/common';
import { EventsModule } from '../events/events.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { MpesaModule } from '../mpesa/mpesa.module';
import { AdminModule } from '../admin/admin.module';
import { PromotionSettingsService } from './settings.service';
import { PackagesService } from './packages.service';
import { CampaignsService } from './campaigns.service';
import { PromotionPaymentsService } from './promotion-payments.service';
import { ServingService } from './serving.service';
import { PromotionAnalyticsService } from './analytics.service';
import { PromotionsSweepService } from './promotions-sweep.service';
import { PromotionsController } from './promotions.controller';
import { PromotionsAdminController } from './promotions-admin.controller';

/**
 * Business Promotion ("Promote Business") — campaigns, packages, M-Pesa
 * purchase, placement serving, analytics, moderation.
 *
 * Boundaries:
 *  - MpesaModule supplies DarajaService (STK) + MpesaService (callback
 *    routing); promotion payments register as an STK-callback fallback
 *    consumer, so this module depends on mpesa — never the reverse.
 *  - AdminModule supplies AdminAuthGuard/AdminAuthService for the admin
 *    controller (same RBAC as the Disputes Centre).
 *  - promotion.* events flow through the existing system_events outbox
 *    (audit-only in the processor; notifications are sent directly here).
 */
@Module({
  imports: [EventsModule, NotificationsModule, MpesaModule, AdminModule],
  controllers: [PromotionsController, PromotionsAdminController],
  providers: [
    PromotionSettingsService,
    PackagesService,
    CampaignsService,
    PromotionPaymentsService,
    ServingService,
    PromotionAnalyticsService,
    PromotionsSweepService,
  ],
})
export class PromotionsModule {}
