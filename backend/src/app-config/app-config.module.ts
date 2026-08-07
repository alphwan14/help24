import { Module } from '@nestjs/common';
import { AdminAuthModule } from '../admin/auth/admin-auth.module';
import { AppConfigAdminController } from './app-config-admin.controller';
import { AppConfigController } from './app-config.controller';
import { AppConfigService } from './app-config.service';

/**
 * The remote configuration plane (Phase 0/1 of the backend-centric
 * transformation — see docs/phase0-1-implementation-plan.md).
 *
 * A leaf module: nothing imports it, and it imports only AdminAuthModule (for
 * the guard on the admin surface). AppConfigService is exported so backend
 * features can later consult the same switches the clients see — a kill
 * switch that only the client honours is a request, not a rule; server-side
 * enforcement arrives with the write-centralization phases.
 */
@Module({
  imports: [AdminAuthModule],
  controllers: [AppConfigController, AppConfigAdminController],
  providers: [AppConfigService],
  exports: [AppConfigService],
})
export class AppConfigModule {}
