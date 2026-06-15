import { Module } from '@nestjs/common';
import { AdminService } from './admin.service';
import { AdminController } from './admin.controller';
import { SupabaseModule } from '../supabase/supabase.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { MpesaModule } from '../mpesa/mpesa.module';
import { EventsModule } from '../events/events.module';

// ── Arbitration (Disputes Centre) ──────────────────────────────────────────────
import { AdminAuthService } from './auth/admin-auth.service';
import { AdminAuthGuard } from './auth/admin-auth.guard';
import { AdminUsersController } from './admin-users.controller';
import { DisputesService } from './disputes/disputes.service';
import { DecisionsService } from './disputes/decisions.service';
import { DisputeRecommendationService } from './disputes/recommendation.service';
import { DisputeSlaService } from './disputes/sla.service';
import { DisputesController } from './disputes/disputes.controller';
import { DisputesPublicController } from './disputes/disputes-public.controller';

@Module({
  imports: [SupabaseModule, NotificationsModule, MpesaModule, EventsModule],
  controllers: [
    AdminController, // legacy dispute resolver (kept for compatibility)
    AdminUsersController,
    DisputesPublicController,
    DisputesController,
  ],
  providers: [
    AdminService,
    // RBAC
    AdminAuthService,
    AdminAuthGuard,
    // Arbitration
    DisputesService,
    DecisionsService,
    DisputeRecommendationService,
    DisputeSlaService,
  ],
})
export class AdminModule {}
