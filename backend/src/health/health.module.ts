import { Module } from '@nestjs/common';
import { RedisModule } from '../redis/redis.module';
import { SupabaseModule } from '../supabase/supabase.module';
import { FirebaseAdminModule } from '../notifications/firebase-admin.module';
import { HealthController, RootController } from './health.controller';
import { HealthService } from './health.service';

/**
 * Health checks.
 *
 * One of exactly two modules that import RedisModule — see redis.module.ts for
 * why that list is kept short and explicit.
 */
@Module({
  imports: [SupabaseModule, RedisModule, FirebaseAdminModule],
  controllers: [HealthController, RootController],
  providers: [HealthService],
})
export class HealthModule {}
