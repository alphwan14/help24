import { ExecutionContext, HttpException, HttpStatus } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { RATE_LIMIT_POLICY_KEY, RATE_LIMIT_SKIP_KEY } from './rate-limit.decorator';
import { RateLimitGuard } from './rate-limit.guard';
import { RateLimitService } from './rate-limit.service';
import { RateLimitDecision } from './rate-limit.types';
import { RequestContextStore } from '../request-context/request-context';

function fakeContext(overrides: { body?: unknown; query?: unknown; params?: unknown } = {}) {
  const headers: Record<string, string> = {};
  const req = {
    method: 'POST',
    path: '/mpesa/initiate',
    ip: '196.201.1.1',
    socket: {},
    body: overrides.body ?? {},
    query: overrides.query ?? {},
    params: overrides.params ?? {},
  };
  const res = {
    setHeader: (name: string, value: string) => {
      headers[name] = value;
    },
  };

  const context = {
    getType: () => 'http',
    getHandler: () => () => undefined,
    getClass: () => class {},
    switchToHttp: () => ({ getRequest: () => req, getResponse: () => res }),
  } as unknown as ExecutionContext;

  return { context, headers, req };
}

function reflectorReturning(values: Record<string, unknown>): Reflector {
  return {
    getAllAndOverride: (key: string) => values[key],
  } as unknown as Reflector;
}

function limiterReturning(decision: RateLimitDecision): RateLimitService {
  return {
    resolvePolicy: (name?: string) => ({
      name: name ?? 'default',
      rationale: 'test',
      rules: [{ id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: 1000, limit: 5 }],
    }),
    check: () => Promise.resolve(decision),
  } as unknown as RateLimitService;
}

const ALLOWED: RateLimitDecision = {
  allowed: true,
  policy: 'payments:initiate',
  limiting: { ruleId: 'subject', allowed: true, limit: 5, remaining: 3, retryAfterMs: 0 },
  degraded: false,
};

const DENIED: RateLimitDecision = {
  allowed: false,
  policy: 'payments:initiate',
  limiting: { ruleId: 'subject', allowed: false, limit: 5, remaining: 0, retryAfterMs: 42_000 },
  degraded: false,
};

describe('RateLimitGuard', () => {
  it('allows and sets rate-limit headers on a successful request', async () => {
    // Headers on ALLOWED responses are what let a well-behaved client
    // self-throttle instead of discovering the limit by hitting it.
    const { context, headers } = fakeContext();
    const guard = new RateLimitGuard(
      reflectorReturning({ [RATE_LIMIT_POLICY_KEY]: 'payments:initiate' }),
      limiterReturning(ALLOWED),
    );

    await expect(guard.canActivate(context)).resolves.toBe(true);
    expect(headers['RateLimit-Limit']).toBe('5');
    expect(headers['RateLimit-Remaining']).toBe('3');
    expect(headers['RateLimit-Policy']).toBe('payments:initiate');
    // The de facto spelling too, for tooling that only knows X-RateLimit-*.
    expect(headers['X-RateLimit-Remaining']).toBe('3');
  });

  it('throws 429 with Retry-After and a machine-readable body when denied', async () => {
    const { context, headers } = fakeContext();
    const guard = new RateLimitGuard(
      reflectorReturning({ [RATE_LIMIT_POLICY_KEY]: 'payments:initiate' }),
      limiterReturning(DENIED),
    );

    await expect(guard.canActivate(context)).rejects.toBeInstanceOf(HttpException);
    expect(headers['Retry-After']).toBe('42');

    try {
      await guard.canActivate(context);
    } catch (err) {
      const exception = err as HttpException;
      expect(exception.getStatus()).toBe(HttpStatus.TOO_MANY_REQUESTS);
      const body = exception.getResponse() as Record<string, unknown>;
      expect(body.retryAfterSeconds).toBe(42);
      expect(body.policy).toBe('payments:initiate');
    }
  });

  it('rounds Retry-After up, never down to zero', async () => {
    // A Retry-After of 0 invites an immediate retry, which is precisely the
    // behaviour a limiter is trying to stop.
    const { context, headers } = fakeContext();
    const guard = new RateLimitGuard(
      reflectorReturning({ [RATE_LIMIT_POLICY_KEY]: 'payments:initiate' }),
      limiterReturning({
        ...DENIED,
        limiting: { ...DENIED.limiting!, retryAfterMs: 120 },
      }),
    );

    await expect(guard.canActivate(context)).rejects.toBeInstanceOf(HttpException);
    expect(headers['Retry-After']).toBe('1');
  });

  it('respects @SkipRateLimit without consulting the limiter', async () => {
    const { context, headers } = fakeContext();
    const limiter = {
      resolvePolicy: () => {
        throw new Error('should not be called');
      },
      check: () => {
        throw new Error('should not be called');
      },
    } as unknown as RateLimitService;

    const guard = new RateLimitGuard(
      reflectorReturning({ [RATE_LIMIT_SKIP_KEY]: true }),
      limiter,
    );

    await expect(guard.canActivate(context)).resolves.toBe(true);
    expect(Object.keys(headers)).toHaveLength(0);
  });

  it('ignores non-HTTP execution contexts', async () => {
    const guard = new RateLimitGuard(reflectorReturning({}), limiterReturning(DENIED));
    const rpc = { getType: () => 'rpc' } as unknown as ExecutionContext;
    await expect(guard.canActivate(rpc)).resolves.toBe(true);
  });

  it('surfaces degraded mode in a response header', async () => {
    const { context, headers } = fakeContext();
    const guard = new RateLimitGuard(
      reflectorReturning({ [RATE_LIMIT_POLICY_KEY]: 'payments:initiate' }),
      limiterReturning({ ...ALLOWED, degraded: true }),
    );

    await guard.canActivate(context);
    expect(headers['RateLimit-Degraded']).toBe('true');
  });

  it('records the policy and verdict on the request context for the access log', async () => {
    const { context } = fakeContext();
    const guard = new RateLimitGuard(
      reflectorReturning({ [RATE_LIMIT_POLICY_KEY]: 'payments:initiate' }),
      limiterReturning(DENIED),
    );

    await RequestContextStore.run(
      {
        requestId: 'r-1',
        inherited: false,
        method: 'POST',
        path: '/mpesa/initiate',
        ip: '1.1.1.1',
        startedAt: 0,
      },
      async () => {
        await guard.canActivate(context).catch(() => undefined);
        expect(RequestContextStore.get()?.rateLimitPolicy).toBe('payments:initiate');
        expect(RequestContextStore.get()?.rateLimited).toBe(true);
      },
    );
  });

  it('tolerates a non-object body without throwing', async () => {
    // req.body is `any` and can be a string or array before/without a parser.
    const { context } = fakeContext({ body: 'raw-text-body' });
    const guard = new RateLimitGuard(
      reflectorReturning({ [RATE_LIMIT_POLICY_KEY]: 'payments:initiate' }),
      limiterReturning(ALLOWED),
    );
    await expect(guard.canActivate(context)).resolves.toBe(true);
  });
});
