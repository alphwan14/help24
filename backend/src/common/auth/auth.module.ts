import { Global, Module } from '@nestjs/common';
import { APP_GUARD, DiscoveryModule } from '@nestjs/core';
import { FirebaseAdminModule } from '../../notifications/firebase-admin.module';
import { AuthGuard } from './auth.guard';
import { TokenVerifierService } from './token-verifier.service';
import { RouteAuditService } from './route-audit.service';
import { loadAuthConfig } from './auth.config';
import { AUTH_CONFIG } from './auth.tokens';

/**
 * Authentication: one verifier, one guard, one boot-time audit.
 *
 * GLOBAL, because IdentityMiddleware needs TokenVerifierService and is
 * instantiated in AppModule's injector rather than in this module's. That is
 * the same trap IdentityModule documents about FirebaseAdminService: middleware
 * applied in `AppModule.configure()` resolves its dependencies from AppModule,
 * so a provider only exported from here would not be reachable. `@Global` makes
 * the verifier resolvable everywhere without every module having to import this
 * one — appropriate for a cross-cutting concern that is, by design, a singleton.
 *
 * AUTH_CONFIG is provided as a VALUE, resolved once at module construction.
 * Four components read the mode — the guard, the audit, the boot banner and the
 * health surface — and they must never disagree about it. Reading the
 * environment in each of them would make a mid-flight variable change produce a
 * process where enforcement is half on, which is the one state harder to debug
 * than either extreme.
 *
 * ⚠️ REGISTRATION ORDER IS LOAD-BEARING. AppModule imports RateLimitModule
 * BEFORE this module, and multiple APP_GUARD providers execute in registration
 * order. Rate limiting must run first so that a flood of unauthenticated
 * requests is rejected by the cheap check, before any identity handling. See
 * the comment in app.module.ts.
 */
@Global()
@Module({
  imports: [DiscoveryModule, FirebaseAdminModule],
  providers: [
    { provide: AUTH_CONFIG, useFactory: () => loadAuthConfig() },
    TokenVerifierService,
    RouteAuditService,
    { provide: APP_GUARD, useClass: AuthGuard },
  ],
  exports: [TokenVerifierService, AUTH_CONFIG],
})
export class AuthModule {}
