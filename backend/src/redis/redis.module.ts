import { Module } from '@nestjs/common';
import { RedisService } from './redis.service';

/**
 * The Redis infrastructure module.
 *
 * NOT `@Global()`, on purpose.
 *
 * A global module would let any of the twenty-odd feature modules inject
 * RedisService without declaring it — which is exactly how "one clean
 * infrastructure layer" decays into Redis calls scattered through business
 * logic, each with its own idea of what to do when the connection is down.
 * Requiring an explicit import means the set of modules that depend on Redis
 * is visible in the import graph and reviewable in a diff.
 *
 * Today that set is two: RateLimitModule and HealthModule.
 */
@Module({
  providers: [RedisService],
  exports: [RedisService],
})
export class RedisModule {}
