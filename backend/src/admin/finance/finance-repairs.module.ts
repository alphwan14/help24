import { Module } from '@nestjs/common';
import { AdminAuthModule } from '../auth/admin-auth.module';
import { MpesaModule } from '../../mpesa/mpesa.module';
import { AdminAlertsModule } from '../alerts/admin-alerts.module';
import { FinanceRepairsController } from './finance-repairs.controller';
import { FinanceRepairsService } from './finance-repairs.service';

/** The finance repairs of migration 117: manual settlements and applying a ruling on record. */
@Module({
  imports: [AdminAuthModule, MpesaModule, AdminAlertsModule],
  controllers: [FinanceRepairsController],
  providers: [FinanceRepairsService],
})
export class FinanceRepairsModule {}
