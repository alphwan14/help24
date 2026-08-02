import { Module } from '@nestjs/common';
import { AdminService } from './admin.service';
import { AdminController } from './admin.controller';
import { SupabaseModule } from '../supabase/supabase.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { MpesaModule } from '../mpesa/mpesa.module';
import { EventsModule } from '../events/events.module';

// ── Arbitration (Disputes Centre) ──────────────────────────────────────────────
import { AdminAuthModule } from './auth/admin-auth.module';
import { AdminAuthService } from './auth/admin-auth.service';
import { AdminAuthGuard } from './auth/admin-auth.guard';
import { AdminInvitesService } from './auth/admin-invites.service';
import { AdminUsersController } from './admin-users.controller';
import { AdminInvitesPublicController } from './admin-invites-public.controller';
import { DisputesService } from './disputes/disputes.service';
import { DecisionsService } from './disputes/decisions.service';
import { DisputeRecommendationService } from './disputes/recommendation.service';
import { DisputeSlaService } from './disputes/sla.service';
import { DisputeStorageService } from './disputes/dispute-storage.service';
import { DisputesController } from './disputes/disputes.controller';
import { DisputesPublicController } from './disputes/disputes-public.controller';

@Module({
  imports: [SupabaseModule, NotificationsModule, MpesaModule, EventsModule, AdminAuthModule],
  controllers: [
    AdminController, // legacy dispute resolver (kept for compatibility)
    AdminUsersController,
    AdminInvitesPublicController,
    DisputesPublicController,
    DisputesController,
  ],
  providers: [
    AdminService,
    // RBAC — AdminAuthService/AdminAuthGuard come from AdminAuthModule.
    AdminInvitesService,
    // Arbitration
    DisputesService,
    DecisionsService,
    DisputeRecommendationService,
    DisputeSlaService,
    DisputeStorageService,
  ],
  // Re-exported so feature modules (e.g. PromotionsModule) can guard their own
  // admin controllers with the same RBAC instead of duplicating it. Importers
  // that already asked AdminModule for AdminAuthGuard keep working; new ones
  // should import AdminAuthModule directly, which carries none of the
  // arbitration graph.
  exports: [AdminAuthModule],
})
export class AdminModule {}
