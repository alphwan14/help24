import { ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { AuthGuard } from './auth.guard';
import { AUTH_SPEC_KEY, Auth, Public, AdminAuth } from './auth.decorator';
import { AuthConfig } from './auth.config';
import { AuthenticatedIdentity, AuthFailureReason } from './auth.types';
import { RequestContextStore } from '../request-context/request-context';

const UID = 'uid-caller';
const OTHER = 'uid-someone-else';

function identity(uid = UID): AuthenticatedIdentity {
  return { uid, expiresAt: Math.floor(Date.now() / 1000) + 3600 };
}

function config(overrides: Partial<AuthConfig> = {}): AuthConfig {
  return {
    mode: 'enforce',
    enforceOnly: [],
    cacheEnabled: true,
    cacheMaxEntries: 100,
    cacheMaxTtlMs: 60_000,
    ...overrides,
  };
}

/** Pull the AuthSpec a decorator produced, without needing Nest to run. */
function specOf(decorator: MethodDecorator & ClassDecorator) {
  class Probe {}
  (decorator as ClassDecorator)(Probe);
  return Reflect.getMetadata(AUTH_SPEC_KEY, Probe);
}

interface FakeRequest {
  method: string;
  path: string;
  body?: unknown;
  query?: unknown;
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

function request(overrides: Partial<FakeRequest> = {}): FakeRequest {
  return { method: 'POST', path: '/jobs/approve', headers: {}, body: {}, ...overrides };
}

beforeEach(() => {
  jest.spyOn(RequestContextStore, 'annotate').mockImplementation(() => undefined);
  jest.spyOn(console, 'warn').mockImplementation(() => undefined);
  jest.spyOn(console, 'error').mockImplementation(() => undefined);
});

afterEach(() => jest.restoreAllMocks());

describe('AuthGuard — enforce mode, protected route', () => {
  const spec = specOf(Auth('body.client_user_id'));

  it('401s an anonymous caller', () => {
    const req = request({ authFailure: { reason: 'absent' } });
    expect(() => guardFor(spec, config()).canActivate(contextFor(req))).toThrow(
      expect.objectContaining({ status: 401 }),
    );
  });

  it('distinguishes an expired token from an invalid one, so the client can refresh', () => {
    // The most consequential part of the error contract. TOKEN_EXPIRED means
    // "refresh and retry"; TOKEN_INVALID means "sign out". Conflating them
    // signs users out over an ordinary hourly expiry.
    const expired = request({ authFailure: { reason: 'expired' } });
    expect(() => guardFor(spec, config()).canActivate(contextFor(expired))).toThrow(
      expect.objectContaining({
        response: expect.objectContaining({ code: 'TOKEN_EXPIRED' }),
      }),
    );

    const invalid = request({ authFailure: { reason: 'invalid' } });
    expect(() => guardFor(spec, config()).canActivate(contextFor(invalid))).toThrow(
      expect.objectContaining({
        response: expect.objectContaining({ code: 'TOKEN_INVALID' }),
      }),
    );
  });

  it('answers 503, never 401, when verification could not be performed', () => {
    // Firebase being unreachable is our fault, not the caller's. A 401 here
    // would tell every signed-in user their session is bad, simultaneously,
    // over an outage none of them caused.
    const req = request({ authFailure: { reason: 'unavailable' } });
    expect(() => guardFor(spec, config()).canActivate(contextFor(req))).toThrow(
      expect.objectContaining({
        status: 503,
        response: expect.objectContaining({ code: 'AUTH_UNAVAILABLE' }),
      }),
    );
  });

  it('injects the verified uid when the field is absent', () => {
    const req = request({ auth: identity(), body: { post_id: 'p1' } });
    expect(guardFor(spec, config()).canActivate(contextFor(req))).toBe(true);
    expect(req.body).toEqual({ post_id: 'p1', client_user_id: UID });
  });

  it('403s when the body claims a different identity', () => {
    const req = request({ auth: identity(), body: { client_user_id: OTHER } });
    expect(() => guardFor(spec, config()).canActivate(contextFor(req))).toThrow(
      expect.objectContaining({
        status: 403,
        response: expect.objectContaining({ code: 'IDENTITY_CONFLICT' }),
      }),
    );
  });
});

describe('AuthGuard — monitor mode', () => {
  const spec = specOf(Auth('body.client_user_id'));
  const monitor = config({ mode: 'monitor' });

  it('allows an anonymous caller through unchanged', () => {
    // The compatibility promise: a shipped client that sends no token keeps
    // working, and its asserted values are left exactly as they arrived.
    const req = request({ authFailure: { reason: 'absent' }, body: { client_user_id: OTHER } });
    expect(guardFor(spec, monitor).canActivate(contextFor(req))).toBe(true);
    expect(req.body).toEqual({ client_user_id: OTHER });
  });

  it('CORRECTS a conflict rather than merely logging it', () => {
    // Monitor is not a purely diagnostic stage. A caller holding a valid token
    // cannot act as someone else even before enforcement is switched on.
    const req = request({ auth: identity(), body: { client_user_id: OTHER } });
    expect(guardFor(spec, monitor).canActivate(contextFor(req))).toBe(true);
    expect(req.body).toEqual({ client_user_id: UID });
  });

  it('still binds for an authenticated caller, so new clients are already safe', () => {
    const req = request({ auth: identity(), body: { post_id: 'p1' } });
    expect(guardFor(spec, monitor).canActivate(contextFor(req))).toBe(true);
    expect(req.body).toEqual({ post_id: 'p1', client_user_id: UID });
  });
});

describe('AuthGuard — off mode', () => {
  it('is indistinguishable from the pre-auth behaviour for an old client', () => {
    const spec = specOf(Auth('body.client_user_id'));
    const req = request({ authFailure: { reason: 'absent' }, body: { client_user_id: OTHER } });
    expect(guardFor(spec, config({ mode: 'off' })).canActivate(contextFor(req))).toBe(true);
    expect(req.body).toEqual({ client_user_id: OTHER });
  });
});

describe('AuthGuard — public routes', () => {
  it('never rejects, with or without an identity', () => {
    const spec = specOf(Public('anonymous browsing', { bind: 'query.user_id' }));
    const anon = request({ method: 'GET', path: '/feed', query: {}, authFailure: { reason: 'absent' } });
    expect(guardFor(spec, config()).canActivate(contextFor(anon))).toBe(true);
  });

  it('drops an anonymous personalisation claim under enforcement', () => {
    const spec = specOf(Public('anonymous browsing', { bind: 'query.user_id' }));
    const req = request({
      method: 'GET',
      path: '/feed',
      query: { user_id: OTHER, lat: '-1.28' },
      authFailure: { reason: 'absent' },
    });
    expect(guardFor(spec, config()).canActivate(contextFor(req))).toBe(true);
    expect(req.query).toEqual({ lat: '-1.28' });
  });

  it('overrides a mismatched claim with the verified identity, without rejecting', () => {
    const spec = specOf(Public('anonymous browsing', { bind: 'query.user_id' }));
    const req = request({
      method: 'GET',
      path: '/feed',
      query: { user_id: OTHER },
      auth: identity(),
    });
    expect(guardFor(spec, config()).canActivate(contextFor(req))).toBe(true);
    expect(req.query).toEqual({ user_id: UID });
  });

  it('a public route with no bindings is a straight pass', () => {
    const spec = specOf(Public('Daraja posts here unauthenticated'));
    const req = request({ path: '/mpesa/stk-callback', authFailure: { reason: 'absent' } });
    expect(guardFor(spec, config()).canActivate(contextFor(req))).toBe(true);
  });
});

describe('AuthGuard — admin scheme', () => {
  it('stands down so AdminAuthGuard can do the work', () => {
    // Admin routes carry an opaque Help24 token, not a Firebase ID token, so
    // this guard must not demand one.
    const spec = specOf(AdminAuth());
    const req = request({ path: '/admin/events', authFailure: { reason: 'absent' } });
    expect(guardFor(spec, config()).canActivate(contextFor(req))).toBe(true);
  });
});

describe('AuthGuard — undeclared routes fail closed', () => {
  it('401s an anonymous caller under enforcement', () => {
    const req = request({ path: '/something/new', authFailure: { reason: 'absent' } });
    expect(() => guardFor(undefined, config()).canActivate(contextFor(req))).toThrow(
      expect.objectContaining({ status: 401 }),
    );
  });

  it('allows it through before enforcement, so the migration is not blocked', () => {
    const req = request({ path: '/something/new', authFailure: { reason: 'absent' } });
    expect(guardFor(undefined, config({ mode: 'monitor' })).canActivate(contextFor(req))).toBe(true);
  });
});

describe('AuthGuard — graduated enforcement via AUTH_ENFORCE_ONLY', () => {
  const spec = specOf(Auth('body.buyer_user_id'));
  const cfg = config({ enforceOnly: ['/MPESA'] });

  it('enforces a listed route', () => {
    const req = request({ path: '/mpesa/initiate', authFailure: { reason: 'absent' } });
    expect(() => guardFor(spec, cfg).canActivate(contextFor(req))).toThrow(
      expect.objectContaining({ status: 401 }),
    );
  });

  it('leaves an unlisted route in monitor behaviour', () => {
    const req = request({ path: '/jobs/approve', authFailure: { reason: 'absent' } });
    expect(guardFor(spec, cfg).canActivate(contextFor(req))).toBe(true);
  });
});

describe('AuthGuard — non-HTTP contexts', () => {
  it('ignores anything that is not a request', () => {
    const ctx = { getType: () => 'rpc' } as unknown as ExecutionContext;
    expect(guardFor(specOf(Auth()), config()).canActivate(ctx)).toBe(true);
  });
});
