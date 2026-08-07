import { ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import 'reflect-metadata';
import { AuthGuard } from './auth.guard';
import { AUTH_SPEC_KEY, AuthCritical, AuthSpec, Public } from './auth.decorator';
import { AuthConfig } from './auth.config';
import { AuthenticatedIdentity, AuthFailureReason } from './auth.types';
import { RequestContextStore } from '../request-context/request-context';
import { PayoutDestinationsController } from '../../payouts/payout-destinations.controller';

/**
 * Regression suite for finding C1 (launch-readiness-verification-report §C1):
 * with enforcement narrowed to /promotions, an unauthenticated production
 * caller reached /payout-destinations on an asserted user_id. These tests pin
 * the fix — critical routes are enforced no matter what the migration env says
 * — and pin the controller so no payout route can quietly lose the flag.
 */

const UID = 'uid-caller';
const OTHER = 'uid-someone-else';

/** The production configuration at the moment C1 was found. */
function productionNarrowedConfig(): AuthConfig {
  return {
    mode: 'enforce',
    enforceOnly: ['/PROMOTIONS'],
    cacheEnabled: true,
    cacheMaxEntries: 100,
    cacheMaxTtlMs: 60_000,
  };
}

function monitorConfig(): AuthConfig {
  return { ...productionNarrowedConfig(), mode: 'monitor', enforceOnly: [] };
}

function identity(uid = UID): AuthenticatedIdentity {
  return { uid, expiresAt: Math.floor(Date.now() / 1000) + 3600 };
}

function specOf(decorator: MethodDecorator & ClassDecorator): AuthSpec {
  class Probe {}
  (decorator as ClassDecorator)(Probe);
  return Reflect.getMetadata(AUTH_SPEC_KEY, Probe) as AuthSpec;
}

interface FakeRequest {
  method: string;
  path: string;
  body?: Record<string, unknown>;
  query?: Record<string, unknown>;
  headers: Record<string, string | undefined>;
  auth?: AuthenticatedIdentity;
  authFailure?: { reason: AuthFailureReason };
}

function contextFor(req: FakeRequest): ExecutionContext {
  return {
    getType: () => 'http',
    switchToHttp: () => ({ getRequest: () => req }),
    getHandler: () => function handler() {},
    getClass: () => class Controller {},
  } as unknown as ExecutionContext;
}

function guardFor(spec: unknown, cfg: AuthConfig): AuthGuard {
  const reflector = { getAllAndOverride: () => spec } as unknown as Reflector;
  return new AuthGuard(reflector, cfg);
}

function payoutRequest(overrides: Partial<FakeRequest> = {}): FakeRequest {
  return {
    method: 'POST',
    path: '/payout-destinations',
    headers: {},
    body: {},
    ...overrides,
  };
}

beforeEach(() => {
  jest.spyOn(RequestContextStore, 'annotate').mockImplementation(() => undefined);
  jest.spyOn(console, 'warn').mockImplementation(() => undefined);
  jest.spyOn(console, 'error').mockImplementation(() => undefined);
});

afterEach(() => jest.restoreAllMocks());

describe('@AuthCritical — the C1 regression matrix', () => {
  const spec = specOf(AuthCritical('body.user_id'));

  it('401s an anonymous caller even under the exact production config that let C1 through', () => {
    const req = payoutRequest({ authFailure: { reason: 'absent' } });
    expect(() =>
      guardFor(spec, productionNarrowedConfig()).canActivate(contextFor(req)),
    ).toThrow(expect.objectContaining({ status: 401 }));
  });

  it('401s an anonymous caller asserting a foreign uid — the exact C1 probe', () => {
    const req = payoutRequest({
      body: { user_id: OTHER, msisdn: '0712345678' },
      authFailure: { reason: 'absent' },
    });
    expect(() =>
      guardFor(spec, productionNarrowedConfig()).canActivate(contextFor(req)),
    ).toThrow(expect.objectContaining({ status: 401 }));
  });

  it('401s an anonymous caller even in monitor mode', () => {
    const req = payoutRequest({ authFailure: { reason: 'absent' } });
    expect(() => guardFor(spec, monitorConfig()).canActivate(contextFor(req))).toThrow(
      expect.objectContaining({ status: 401 }),
    );
  });

  it('admits an authenticated caller and binds their own uid', () => {
    const req = payoutRequest({ auth: identity(), body: {} });
    expect(guardFor(spec, productionNarrowedConfig()).canActivate(contextFor(req))).toBe(true);
    expect(req.body?.user_id).toBe(UID);
  });

  it('admits an authenticated caller naming their own uid unchanged', () => {
    const req = payoutRequest({ auth: identity(), body: { user_id: UID } });
    expect(guardFor(spec, productionNarrowedConfig()).canActivate(contextFor(req))).toBe(true);
    expect(req.body?.user_id).toBe(UID);
  });

  it('403s an authenticated caller naming a FOREIGN uid — never corrected, always denied', () => {
    const req = payoutRequest({ auth: identity(), body: { user_id: OTHER } });
    expect(() =>
      guardFor(spec, productionNarrowedConfig()).canActivate(contextFor(req)),
    ).toThrow(expect.objectContaining({ status: 403 }));
    // And crucially: also denied in monitor mode, where ordinary routes correct.
    const again = payoutRequest({ auth: identity(), body: { user_id: OTHER } });
    expect(() => guardFor(spec, monitorConfig()).canActivate(contextFor(again))).toThrow(
      expect.objectContaining({ status: 403 }),
    );
  });

  it('keeps the 503-on-unavailable contract so an outage does not sign users out', () => {
    const req = payoutRequest({ authFailure: { reason: 'unavailable' } });
    expect(() =>
      guardFor(spec, productionNarrowedConfig()).canActivate(contextFor(req)),
    ).toThrow(expect.objectContaining({ status: 503 }));
  });
});

describe('@AuthCritical — no collateral change to other schemes', () => {
  it('a @Public route still admits an anonymous caller under the same config', () => {
    const spec = specOf(Public('Discover is browsable without an account.'));
    const req = payoutRequest({ path: '/feed', method: 'GET' });
    expect(guardFor(spec, productionNarrowedConfig()).canActivate(contextFor(req))).toBe(true);
  });

  it('an ordinary @Auth route outside the allowlist keeps monitor behaviour (the migration is untouched)', () => {
    const ordinary: AuthSpec = { scheme: 'firebase', bindings: [] };
    const req = payoutRequest({ path: '/jobs/x/status', method: 'GET', authFailure: { reason: 'absent' } });
    expect(guardFor(ordinary, productionNarrowedConfig()).canActivate(contextFor(req))).toBe(true);
  });
});

describe('PayoutDestinationsController — every route is declared critical', () => {
  // The flag only protects money if it is actually on the routes. This walks
  // the real controller metadata, so removing @AuthCritical from any handler —
  // or adding a new handler without it — fails here, not in production.
  const prototype = PayoutDestinationsController.prototype as unknown as Record<string, unknown>;
  const handlerNames = Object.getOwnPropertyNames(prototype).filter(
    (name) => name !== 'constructor' && typeof prototype[name] === 'function',
  );

  it('has the six known handlers', () => {
    expect(handlerNames.sort()).toEqual(
      ['add', 'list', 'requestChallenge', 'retire', 'setDefault', 'verify'].sort(),
    );
  });

  it.each(handlerNames)('%s requires a verified identity unconditionally', (name) => {
    const spec = Reflect.getMetadata(
      AUTH_SPEC_KEY,
      prototype[name] as object,
    ) as AuthSpec | undefined;
    expect(spec).toBeDefined();
    expect(spec?.scheme).toBe('firebase');
    expect(spec?.critical).toBe(true);
    expect(spec?.bindings.length).toBeGreaterThan(0);
  });
});
