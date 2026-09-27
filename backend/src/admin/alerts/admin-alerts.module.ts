import { Module } from '@nestjs/common';
import { AdminAuthModule } from '../auth/admin-auth.module';
import { AdminAlertsController } from './admin-alerts.controller';
import { AdminAlertsService } from './admin-alerts.service';

/**
 * Admin alerts. Imports AdminAuthModule for the guard only — the alerts read
 * records through the global Supabase client and depend on no feature module,
 * so a failure in one feature can never take the alert list down with it.
 */
@Module({
  imports: [AdminAuthModule],
  controllers: [AdminAlertsController],
  providers: [AdminAlertsService],
})
export class AdminAlertsModule {}
