import { CanActivate, ExecutionContext, ForbiddenException, Injectable, Logger } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { AUTH_SPEC_KEY, AuthSpec } from '../common/auth/auth.decorator';
import { RequestWithIdentity } from '../common/auth/auth.types';
import { AccountStateService } from './account-state.service';
import { Capability, Denial } from './moderation.constants';
import { RESTRICT_KEY, actingUserId } from './restrict.decorator';

/**
 * Refuses a `@Restrict(...)` route to an account that is not allowed to do it.
 *
 * Registered globally, AFTER AuthGuard (ModerationEnforcementModule is imported
 * after AuthModule in AppModule), so identity has been verified and bound by
 * the time this runs. Routes without `@Restrict` pay nothing — one metadata
 * read.
 *
 * The body is a stable contract the app branches on:
 *
 *   403 { code: 'ACCOUNT_RESTRICTED', restriction: 'suspended', capability: 'hire', message }
 *
 * `message` is written for the person reading it, and says where to look —
 * never why they were restricted (that is theirs to read in the app, from
 * my_account_status(), not something to put in an error toast).
 */
@Injectable()
export class ModerationGuard implements CanActivate {
  private readonly logger = new Logger(ModerationGuard.name);

  constructor(
    private readonly reflector: Reflector,
    private readonly state: AccountStateService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    if (context.getType() !== 'http') return true;

    const capability = this.reflector.getAllAndOverride<Capability | undefined>(RESTRICT_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (!capability) return true;

    const req = context.switchToHttp().getRequest<RequestWithIdentity & { body?: unknown; query?: unknown; method?: string; path?: string }>();
    const spec = this.reflector.getAllAndOverride<AuthSpec | undefined>(AUTH_SPEC_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);

    const actor = actingUserId(req, spec);
    // No account to check means AuthGuard admitted an anonymous caller (monitor
    // mode) with no asserted id either. The service rejects an empty id on its
    // own terms; there is no restriction to apply to nobody.
    if (!actor) return true;

    const denial = await this.state.denial(actor, capability);
    if (!denial) return true;

    this.logger.warn(
      `[MODERATION][DENIED] ${req.method ?? ''} ${req.path ?? ''} — account=${actor} ` +
        `capability=${capability} restriction=${denial}`,
    );
    throw new ForbiddenException({
      statusCode: 403,
      error: 'Forbidden',
      code: 'ACCOUNT_RESTRICTED',
      restriction: denial,
      capability,
      message: RESTRICTION_MESSAGES[denial],
    });
  }
}

/**
 * What the person is told. Each begins "Your Help24 account", which the app's
 * ErrorMapper recognises, and each points at the in-app Account status screen
 * rather than restating the reason.
 */
export const RESTRICTION_MESSAGES: Readonly<Record<Denial, string>> = {
  banned: 'Your Help24 account has been banned. Open Account status in the app to see why and how to appeal.',
  suspended: 'Your Help24 account is suspended right now. Open Account status in the app to see when it ends.',
  messaging_restricted: "Your Help24 account can't send messages right now. Open Account status in the app for details.",
  marketplace_restricted: "Your Help24 account can't post, apply, hire or pay right now. Open Account status in the app for details.",
};
