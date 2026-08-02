import { Module } from '@nestjs/common';
import { IdentityMiddleware } from './identity.middleware';

/**
 * Provides IdentityMiddleware to AppModule's middleware chain.
 *
 * Its one dependency, TokenVerifierService, comes from AuthModule — which is
 * `@Global()` precisely so that this works. Middleware applied in
 * `AppModule.configure()` is instantiated in AppModule's injector, not in the
 * module that declared it, so a provider merely exported by AuthModule would
 * not be resolvable here unless AppModule itself imported it. Global
 * registration removes that coupling; see the comment in auth.module.ts.
 *
 * ⚠️ AppModule must import AuthModule BEFORE IdentityModule for the verifier to
 * exist when this middleware is constructed.
 */
@Module({
  providers: [IdentityMiddleware],
  exports: [IdentityMiddleware],
})
export class IdentityModule {}
