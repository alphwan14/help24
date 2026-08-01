import { Global, Module } from '@nestjs/common';
import { StructuredLogger } from './structured-logger.service';
import { AccessLogMiddleware } from './access-log.middleware';

/**
 * Logging infrastructure.
 *
 * `@Global()` here, unlike RedisModule, and the difference is the point:
 * Redis is a dependency whose blast radius must stay visible in the import
 * graph, whereas logging is a cross-cutting concern with no failure mode worth
 * containing. Making it global means main.ts can resolve StructuredLogger
 * before any feature module is constructed, which is what lets boot-time logs
 * be formatted by the same writer as everything else.
 *
 * There is exactly ONE StructuredLogger instance in the process: this
 * provider. `app.useLogger()` installs it as Nest's global logger, and
 * AccessLogMiddleware injects the same instance — so log level and format are
 * decided once and cannot drift between the framework's output and ours.
 */
@Global()
@Module({
  providers: [StructuredLogger, AccessLogMiddleware],
  exports: [StructuredLogger, AccessLogMiddleware],
})
export class LoggingModule {}
