import { Module } from '@nestjs/common';
import { MpesaService } from './mpesa.service';
import { MpesaController } from './mpesa.controller';
import { DarajaService } from './daraja.service';
import { TransactionsModule } from '../transactions/transactions.module';

@Module({
  imports: [TransactionsModule],
  controllers: [MpesaController],
  providers: [MpesaService, DarajaService],
})
export class MpesaModule {}
