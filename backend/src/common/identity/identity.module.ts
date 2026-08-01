import { Module } from '@nestjs/common';
import { FirebaseAdminModule } from '../../notifications/firebase-admin.module';
import { IdentityMiddleware } from './identity.middleware';

/**
 * Provides IdentityMiddleware to AppModule's middleware chain.
 *
 * FirebaseAdminModule is RE-EXPORTED, which is the part that is easy to get
 * wrong and fails only at boot. Middleware applied in `AppModule.configure()`
 * is instantiated in AppModule's injector, not in the module that declared it
 * — so exporting IdentityMiddleware alone is not enough: AppModule must also
 * be able to resolve FirebaseAdminService, the dependency the middleware asks
 * for. Re-exporting the module that provides it satisfies that without
 * AppModule needing to know why.
 */
@Module({
  imports: [FirebaseAdminModule],
  providers: [IdentityMiddleware],
  exports: [IdentityMiddleware, FirebaseAdminModule],
})
export class IdentityModule {}
