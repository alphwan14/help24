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
  exports: [MpesaService],
})
export class MpesaModule {}
