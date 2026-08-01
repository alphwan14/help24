import { Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { RedisModule } from '../../redis/redis.module';
import { RateLimitGuard } from './rate-limit.guard';
import { RateLimitService } from './rate-limit.service';

/**
 * Distributed rate limiting.
 *
 * The `APP_GUARD` provider registers RateLimitGuard globally FROM INSIDE the
 * DI container, which matters: `app.useGlobalGuards(new RateLimitGuard(...))`
 * in main.ts would require constructing the guard by hand and wiring its
 * dependencies manually. Registered this way it receives Reflector and
 * RateLimitService by injection, exactly like any other provider.
 *
 * Importing RedisModule here — rather than making Redis global — is what keeps
 * "who depends on Redis?" answerable by reading the import graph.
 */
@Module({
  imports: [RedisModule],
  providers: [RateLimitService, { provide: APP_GUARD, useClass: RateLimitGuard }],
  exports: [RateLimitService],
})
export class RateLimitModule {}
