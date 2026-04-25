import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { configuration } from './config/configuration';
import { SupabaseModule } from './supabase/supabase.module';
import { TransactionsModule } from './transactions/transactions.module';
import { ProvidersModule } from './providers/providers.module';
import { MpesaModule } from './mpesa/mpesa.module';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      load: [configuration],
    }),
    SupabaseModule,
    TransactionsModule,
    ProvidersModule,
    MpesaModule,
  ],
})
export class AppModule {}
