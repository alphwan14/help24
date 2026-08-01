import { SetMetadata } from '@nestjs/common';
import { POLICY_BY_NAME } from './rate-limit.policies';

export const RATE_LIMIT_POLICY_KEY = 'help24:rateLimitPolicy';
export const RATE_LIMIT_SKIP_KEY = 'help24:rateLimitSkip';

/**
 * Declare which policy protects this route.
 *
 *   @RateLimit('payments:initiate')
 *   @Post('initiate')
 *   initiatePayment(@Body() dto: InitiatePaymentDto) { … }
 *
 * Applies to a whole controller when placed on the class; a method-level
 * decorator overrides it.
 *
 * WHY A NAME AND NOT NUMBERS
 * --------------------------
 * The decorator carries no limits, only a reference. Retuning a limit is a
 * one-line edit in the catalogue that needs no knowledge of which controllers
 * use it, and moving an endpoint between controllers cannot lose or change its
 * protection. The alternative — `@RateLimit({ limit: 5, window: 600 })` at the
 * call site — scatters the very constants this design exists to centralise,
 * and makes "what are all our limits?" a grep instead of a file.
 *
 * WHY BINDING BY DECORATOR RATHER THAN A PATH TABLE
 * -------------------------------------------------
 * A central `{ 'POST /mpesa/initiate': 'payments:initiate' }` table would
 * avoid touching controllers at all, but it binds by string. Renaming a route
 * silently drops its limit, and nothing fails at compile time or at boot. A
 * decorator is attached to the handler itself: it moves with the code and
 * cannot be orphaned.
 */
export const RateLimit = (policy: string): MethodDecorator & ClassDecorator => {
  // Fail at module load, not on the first request. An unknown name would
  // otherwise silently fall back to the default policy — the endpoint would
  // still work, just with the wrong protection, which is precisely the kind of
  // mistake that is never noticed until it matters.
  if (!POLICY_BY_NAME.has(policy)) {
    throw new Error(
      `[RateLimit] Unknown policy "${policy}". Known policies: ` +
        `${[...POLICY_BY_NAME.keys()].sort().join(', ')}`,
    );
  }
  return SetMetadata(RATE_LIMIT_POLICY_KEY, policy);
};

/**
 * Exempt a route from rate limiting entirely.
 *
 * Reserved for endpoints where the CHECK costs more than the RESPONSE — see
 * the liveness probe in health.controller.ts, which is the only current use.
 * Every application of this decorator needs a comment justifying it.
 */
export const SkipRateLimit = (): MethodDecorator & ClassDecorator =>
  SetMetadata(RATE_LIMIT_SKIP_KEY, true);
