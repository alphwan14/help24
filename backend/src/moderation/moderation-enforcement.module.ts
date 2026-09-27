import { Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { AccountStateService } from './account-state.service';
import { ModerationGuard } from './moderation.guard';

/**
 * The enforcement half of Trust & Safety, on its own.
 *
 * Split from ModerationModule for ONE reason: APP_GUARD providers run in
 * registration order, and this guard must run after AuthGuard (identity is
 * verified and bound) — so this module is imported immediately after
 * AuthModule in AppModule, alongside the other infrastructure, while the
 * feature (controllers, admin services) is imported with the other features.
 * Same reasoning as AdminAuthModule being split from AdminModule.
 */
@Module({
  providers: [AccountStateService, { provide: APP_GUARD, useClass: ModerationGuard }],
  exports: [AccountStateService],
})
export class ModerationEnforcementModule {}
