import { Module } from '@nestjs/common';
import { MpesaService } from './mpesa.service';
import { MpesaController } from './mpesa.controller';
import { DarajaService } from './daraja.service';
import { TransactionsModule } from '../transactions/transactions.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { EventsModule } from '../events/events.module';

@Module({
  imports: [TransactionsModule, NotificationsModule, EventsModule],
  controllers: [MpesaController],
  providers: [MpesaService, DarajaService],
  // DarajaService is exported for PromotionsModule: promotion purchases reuse
  // the same STK client (and callback URL) without duplicating Daraja auth.
  exports: [MpesaService, DarajaService],
})
export class MpesaModule {}
