import { Module } from '@nestjs/common';
import { MpesaService } from './mpesa.service';
import { MpesaController } from './mpesa.controller';
import { DarajaService } from './daraja.service';
import { MaterialsAdvanceService } from './materials-advance.service';
import { TransactionsModule } from '../transactions/transactions.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { EventsModule } from '../events/events.module';
// AdminAuthModule, NOT AdminModule: `POST /mpesa/release-payout` is guarded by
// AdminAuthGuard, and AdminModule imports THIS module — importing it back would
// close a cycle. See admin-auth.module.ts.
import { AdminAuthModule } from '../admin/auth/admin-auth.module';
import { PayoutsModule } from '../payouts/payouts.module';

@Module({
  imports: [TransactionsModule, NotificationsModule, EventsModule, AdminAuthModule, PayoutsModule],
  controllers: [MpesaController],
  providers: [MpesaService, DarajaService, MaterialsAdvanceService],
  // DarajaService is exported for PromotionsModule: promotion purchases reuse
  // the same STK client (and callback URL) without duplicating Daraja auth.
  // MaterialsAdvanceService is exported for disputes (freeze + decision math).
  exports: [MpesaService, DarajaService, MaterialsAdvanceService],
})
export class MpesaModule {}
