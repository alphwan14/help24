import { SetMetadata } from '@nestjs/common';
import { AuthSpec } from '../common/auth/auth.decorator';
import { AuthenticatedIdentity } from '../common/auth/auth.types';
import { CAPABILITIES, Capability } from './moderation.constants';

export const RESTRICT_KEY = 'help24:restrictCapability';

/**
 * This route exercises a capability that account restrictions can take away.
 *
 *   @Restrict('hire')
 *   @Auth('body.client_user_id')
 *   @Post('select-provider')
 *
 * ModerationGuard reads it after AuthGuard and refuses the request with 403
 * `ACCOUNT_RESTRICTED` when the acting account may not do this. What each
 * restriction blocks is decided by the database (`moderation_denial`), not
 * here — the decorator only names the capability.
 *
 * WHICH ROUTES CARRY IT, AND WHICH DELIBERATELY DO NOT
 * ----------------------------------------------------
 * Routes that create a NEW commitment or reach another person: selecting a
 * provider, paying, marking work done, reviewing, promoting, messaging,
 * configuring payouts. Routes that SETTLE an existing obligation — approving a
 * completion, raising or answering a dispute, reading receipts — carry none,
 * because blocking them strands the innocent counterparty's money or leaves a
 * sanctioned person no way to contest a decision. The full map is pinned in
 * moderation.contract.spec.ts; adding or removing a decorator fails it.
 *
 * Fails at module load on an unknown capability, the same way @RateLimit does
 * for an unknown policy: a typo that silently restricted nothing would look
 * exactly like a restriction that works.
 */
export const Restrict = (capability: Capability): MethodDecorator & ClassDecorator => {
  if (!(CAPABILITIES as readonly string[]).includes(capability)) {
    throw new Error(`[Moderation] Unknown capability "${capability}" in @Restrict().`);
  }
  return SetMetadata(RESTRICT_KEY, capability);
};

/**
 * The account a request ACTS AS — the one a restriction must be checked
 * against.
 *
 * A verified token wins outright. Without one (production still runs most
 * routes in monitor mode — see auth.config.ts), the route's first declared
 * identity binding is the account the service will act as, so that is the
 * account checked. Checking anything else would let a restricted caller act
 * under their own asserted id by simply omitting a token.
 *
 * Asserting SOMEONE ELSE's id without a token is impersonation, a gap the auth
 * migration owns (AUTH_ENFORCEMENT); it is not re-litigated here.
 */
export function actingUserId(
  req: { auth?: AuthenticatedIdentity; body?: unknown; query?: unknown },
  spec: AuthSpec | undefined,
): string | null {
  if (req.auth?.uid) return req.auth.uid;
  for (const binding of spec?.bindings ?? []) {
    const bag = (binding.source === 'body' ? req.body : req.query) as Record<string, unknown> | undefined;
    const value = bag && typeof bag === 'object' ? bag[binding.field] : undefined;
    if (typeof value === 'string' && value.trim() !== '') return value.trim();
  }
  return null;
}
