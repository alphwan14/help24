import { ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import 'reflect-metadata';
import { AUTH_SPEC_KEY, AuthSpec } from '../common/auth/auth.decorator';
import { parseBinding } from '../common/auth/identity-binding';
import { AccountStateService } from './account-state.service';
import { Capability, Denial } from './moderation.constants';
import { ModerationGuard, RESTRICTION_MESSAGES } from './moderation.guard';
import { RESTRICT_KEY, Restrict, actingUserId } from './restrict.decorator';

interface FakeReq {
  method: string;
  path: string;
  auth?: { uid: string; expiresAt: number };
  body?: Record<string, unknown>;
  query?: Record<string, unknown>;
}

function contextFor(req: FakeReq, type = 'http'): ExecutionContext {
  return {
    getType: () => type,
    switchToHttp: () => ({ getRequest: () => req }),
    getHandler: () => function handler() {},
    getClass: () => class Controller {},
  } as unknown as ExecutionContext;
}

function guardFor(capability: Capability | undefined, spec: AuthSpec | undefined, denial: Denial | null) {
  const reflector = {
    getAllAndOverride: (key: string) => (key === RESTRICT_KEY ? capability : key === AUTH_SPEC_KEY ? spec : undefined),
  } as unknown as Reflector;
  const state = { denial: jest.fn().mockResolvedValue(denial) };
  return { guard: new ModerationGuard(reflector, state as unknown as AccountStateService), state };
}

const clientSpec: AuthSpec = { scheme: 'firebase', bindings: [parseBinding('body.client_user_id', 'required')] };

beforeEach(() => {
  jest.spyOn(console, 'warn').mockImplementation(() => undefined);
});
afterEach(() => jest.restoreAllMocks());

describe('ModerationGuard', () => {
  it('ignores routes that name no capability, without a database call', async () => {
    const { guard, state } = guardFor(undefined, clientSpec, 'banned');
    await expect(guard.canActivate(contextFor({ method: 'POST', path: '/x', body: { client_user_id: 'u1' } }))).resolves.toBe(true);
    expect(state.denial).not.toHaveBeenCalled();
  });

  it('ignores non-HTTP contexts (background sweeps)', async () => {
    const { guard, state } = guardFor('hire', clientSpec, 'banned');
    await expect(guard.canActivate(contextFor({ method: 'POST', path: '/x' }, 'rpc'))).resolves.toBe(true);
    expect(state.denial).not.toHaveBeenCalled();
  });

  it('admits an account with no restriction', async () => {
    const { guard, state } = guardFor('hire', clientSpec, null);
    const req = { method: 'POST', path: '/jobs/select-provider', auth: { uid: 'u1', expiresAt: 0 }, body: {} };
    await expect(guard.canActivate(contextFor(req))).resolves.toBe(true);
    expect(state.denial).toHaveBeenCalledWith('u1', 'hire');
  });

  it('refuses a restricted account with the machine-readable contract the app branches on', async () => {
    const { guard } = guardFor('hire', clientSpec, 'suspended');
    const req = { method: 'POST', path: '/jobs/select-provider', auth: { uid: 'u1', expiresAt: 0 }, body: {} };
    const error = await guard.canActivate(contextFor(req)).catch((e: unknown) => e);
    expect(error).toMatchObject({ status: 403 });
    expect((error as { getResponse(): unknown }).getResponse()).toEqual({
      statusCode: 403,
      error: 'Forbidden',
      code: 'ACCOUNT_RESTRICTED',
      restriction: 'suspended',
      capability: 'hire',
      message: RESTRICTION_MESSAGES.suspended,
    });
  });

  it('checks the VERIFIED uid, not a body field naming someone else', async () => {
    const { guard, state } = guardFor('hire', clientSpec, null);
    const req = { method: 'POST', path: '/x', auth: { uid: 'verified', expiresAt: 0 }, body: { client_user_id: 'asserted' } };
    await guard.canActivate(contextFor(req));
    expect(state.denial).toHaveBeenCalledWith('verified', 'hire');
  });

  it('without a token, checks the identity the service will act as (the route\'s binding)', async () => {
    const { guard, state } = guardFor('hire', clientSpec, 'banned');
    const req = { method: 'POST', path: '/x', body: { client_user_id: 'banned-person' } };
    await expect(guard.canActivate(contextFor(req))).rejects.toMatchObject({ status: 403 });
    expect(state.denial).toHaveBeenCalledWith('banned-person', 'hire');
  });

  it('has nobody to check when there is neither a token nor an asserted id', async () => {
    const { guard, state } = guardFor('hire', clientSpec, 'banned');
    await expect(guard.canActivate(contextFor({ method: 'POST', path: '/x', body: {} }))).resolves.toBe(true);
    expect(state.denial).not.toHaveBeenCalled();
  });

  it('every refusal message starts the way the app\'s ErrorMapper recognises', () => {
    for (const message of Object.values(RESTRICTION_MESSAGES)) {
      expect(message.startsWith('Your Help24 account')).toBe(true);
      expect(message.length).toBeLessThanOrEqual(120);
    }
  });
});

describe('@Restrict / actingUserId', () => {
  it('refuses an unknown capability at load time', () => {
    expect(() => Restrict('teleport' as Capability)).toThrow(/Unknown capability/);
  });

  it('reads query bindings too', () => {
    const spec: AuthSpec = { scheme: 'firebase', bindings: [parseBinding('query.user_id', 'required')] };
    expect(actingUserId({ query: { user_id: ' u9 ' } }, spec)).toBe('u9');
    expect(actingUserId({ query: {} }, spec)).toBeNull();
  });
});
