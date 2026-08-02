import { Module } from '@nestjs/common';
import { SupabaseModule } from '../../supabase/supabase.module';
import { AdminAuthService } from './admin-auth.service';
import { AdminAuthGuard } from './admin-auth.guard';

/**
 * Admin authentication, on its own, importable by anyone.
 *
 * WHY THIS IS SPLIT OUT OF AdminModule
 * ------------------------------------
 * AdminAuthGuard needs only `AdminAuthService`, which needs only Supabase and
 * config. AdminModule, by contrast, pulls in the entire arbitration feature
 * graph — disputes, decisions, SLA, storage — AND `MpesaModule`, because
 * dispute resolution moves money.
 *
 * That last import is what forced this module to exist. `MpesaController` now
 * guards `POST /mpesa/release-payout` with AdminAuthGuard, and MpesaModule
 * importing AdminModule to get it would have closed a cycle:
 * AdminModule → MpesaModule → AdminModule. `forwardRef` would paper over that,
 * at the cost of a dependency graph that only resolves by luck of
 * initialisation order.
 *
 * Separating the guard from the feature it happens to live next to removes the
 * cycle outright, and states the real relationship: admin authentication is
 * infrastructure that several feature modules consume, not a part of the
 * disputes centre.
 *
 * AdminModule re-exports this, so existing importers (PromotionsModule) that
 * ask AdminModule for the guard keep working unchanged.
 */
@Module({
  imports: [SupabaseModule],
  providers: [AdminAuthService, AdminAuthGuard],
  exports: [AdminAuthService, AdminAuthGuard],
})
export class AdminAuthModule {}
