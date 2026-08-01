import { RedisService, RedisUnavailableError, ScriptResult } from '../../redis/redis.service';
import { RateLimitService } from './rate-limit.service';
import { RateLimitPolicy } from './rate-limit.types';

/**
 * A stand-in for RedisService that records calls and can be told to fail.
 * The real client is not exercised here — script BEHAVIOUR is verified against
 * a live server in redis-scripts.integration.spec.ts.
 */
class FakeRedis {
  available = true;
  readonly slidingCalls: Array<{ key: string; windowMs: number; limit: number; cost: number }> = [];
  readonly bucketCalls: Array<{ key: string; capacity: number }> = [];
  /** Queue of results to return, in order. Defaults to "allowed". */
  results: ScriptResult[] = [];

  get isAvailable(): boolean {
    return this.available;
  }
  get isConfigured(): boolean {
    return true;
  }
  get status(): string {
    return this.available ? 'ready' : 'end';
  }
  get keyPrefix(): string {
    return 'help24:test';
  }

  private next(fallback: ScriptResult): ScriptResult {
    if (!this.available) throw new RedisUnavailableError('end');
    return this.results.shift() ?? fallback;
  }

  slidingWindow(key: string, windowMs: number, limit: number, cost: number): Promise<ScriptResult> {
    this.slidingCalls.push({ key, windowMs, limit, cost });
    return Promise.resolve(
      this.next({ allowed: true, limit, remaining: limit - cost, retryAfterMs: 0 }),
    );
  }

  tokenBucket(key: string, capacity: number): Promise<ScriptResult> {
    this.bucketCalls.push({ key, capacity });
    return Promise.resolve(
      this.next({ allowed: true, limit: capacity, remaining: capacity - 1, retryAfterMs: 0 }),
    );
  }
}

function serviceWith(redis: FakeRedis): RateLimitService {
  return new RateLimitService(redis as unknown as RedisService);
}

const TWO_RULE_POLICY: RateLimitPolicy = {
  name: 'test:two-rule',
  rationale: 'test',
  rules: [
    {
      id: 'subject',
      algorithm: 'sliding-window',
      by: ['auth.uid', 'body.user_id', 'query.user_id'],
      windowMs: 60_000,
      limit: 5,
    },
    { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: 60_000, limit: 50 },
  ],
};

describe('RateLimitService — subject resolution', () => {
  it('prefers a VERIFIED identity over an asserted one', async () => {
    // Once the app sends tokens, per-subject limits must key on the proven
    // uid. Spoofing `user_id` must not move the caller to a fresh bucket.
    const spoofing = new FakeRedis();
    const honest = new FakeRedis();

    await serviceWith(spoofing).check(TWO_RULE_POLICY, {
      ip: '1.1.1.1',
      auth: { uid: 'firebase-uid' },
      body: { user_id: 'claimed-someone-else' },
    });
    await serviceWith(honest).check(TWO_RULE_POLICY, {
      ip: '1.1.1.1',
      auth: { uid: 'firebase-uid' },
    });

    expect(spoofing.slidingCalls[0].key).toBe(honest.slidingCalls[0].key);
  });

  it('uses the asserted id only when no verified identity exists', async () => {
    const asserted = new FakeRedis();
    const verified = new FakeRedis();

    await serviceWith(asserted).check(TWO_RULE_POLICY, { ip: '1.1.1.1', body: { user_id: 'u-1' } });
    await serviceWith(verified).check(TWO_RULE_POLICY, { ip: '1.1.1.1', auth: { uid: 'u-1' } });

    // Same VALUE, different SOURCE — and therefore a different bucket, so a
    // caller cannot claim a verified user's remaining budget by guessing
    // their id.
    expect(asserted.slidingCalls[0].key).not.toBe(verified.slidingCalls[0].key);
  });

  it('produces the same key for the same identity and different keys for different ones', async () => {
    const a = new FakeRedis();
    const b = new FakeRedis();
    await serviceWith(a).check(TWO_RULE_POLICY, { ip: '1.1.1.1', body: { user_id: 'u-1' } });
    await serviceWith(b).check(TWO_RULE_POLICY, { ip: '1.1.1.1', body: { user_id: 'u-2' } });

    expect(a.slidingCalls[0].key).not.toBe(b.slidingCalls[0].key);
    // ...but the IP rule, keyed on the same address, must match.
    expect(a.slidingCalls[1].key).toBe(b.slidingCalls[1].key);
  });

  it('falls back to the IP when no subject field is present', async () => {
    // Falling back rather than skipping matters: a rule that stopped applying
    // because a field was missing would be an evasion technique.
    const redis = new FakeRedis();
    await serviceWith(redis).check(TWO_RULE_POLICY, { ip: '9.9.9.9' });
    expect(redis.slidingCalls).toHaveLength(2);
  });

  it('never puts a raw identity in the key', async () => {
    // Redis is a lower-trust store than the database; `KEYS *` must not
    // enumerate user ids or IP addresses.
    const redis = new FakeRedis();
    await serviceWith(redis).check(TWO_RULE_POLICY, {
      ip: '196.201.214.200',
      body: { user_id: 'sensitive-user-id' },
    });

    for (const call of redis.slidingCalls) {
      expect(call.key).not.toContain('sensitive-user-id');
      expect(call.key).not.toContain('196.201.214.200');
    }
  });

  it('namespaces keys by policy, rule and environment prefix', async () => {
    const redis = new FakeRedis();
    await serviceWith(redis).check(TWO_RULE_POLICY, { ip: '1.1.1.1' });
    expect(redis.slidingCalls[0].key).toMatch(/^help24:test:rl:test:two-rule:subject:[0-9a-f]{16}$/);
    expect(redis.slidingCalls[1].key).toMatch(/^help24:test:rl:test:two-rule:ip:[0-9a-f]{16}$/);
  });
});

describe('RateLimitService — evaluation', () => {
  it('allows when every rule allows, and reports the tightest as limiting', async () => {
    const redis = new FakeRedis();
    redis.results = [
      { allowed: true, limit: 5, remaining: 4, retryAfterMs: 0 },
      { allowed: true, limit: 50, remaining: 49, retryAfterMs: 0 },
    ];

    const decision = await serviceWith(redis).check(TWO_RULE_POLICY, { ip: '1.1.1.1' });

    expect(decision.allowed).toBe(true);
    // The client should see the constraint that will bite first, not the
    // most permissive one.
    expect(decision.limiting?.ruleId).toBe('subject');
    expect(decision.limiting?.remaining).toBe(4);
  });

  it('short-circuits: a denial by the first rule never consumes the second', async () => {
    // Ordering is subject-before-IP precisely so a heavy individual is stopped
    // by their own budget before spending the shared IP budget that everyone
    // else behind the same NAT depends on.
    const redis = new FakeRedis();
    redis.results = [{ allowed: false, limit: 5, remaining: 0, retryAfterMs: 30_000 }];

    const decision = await serviceWith(redis).check(TWO_RULE_POLICY, { ip: '1.1.1.1' });

    expect(decision.allowed).toBe(false);
    expect(decision.limiting?.ruleId).toBe('subject');
    expect(redis.slidingCalls).toHaveLength(1); // the IP rule was never evaluated
  });

  it('denies when a later rule denies', async () => {
    const redis = new FakeRedis();
    redis.results = [
      { allowed: true, limit: 5, remaining: 4, retryAfterMs: 0 },
      { allowed: false, limit: 50, remaining: 0, retryAfterMs: 12_000 },
    ];

    const decision = await serviceWith(redis).check(TWO_RULE_POLICY, { ip: '1.1.1.1' });
    expect(decision.allowed).toBe(false);
    expect(decision.limiting?.ruleId).toBe('ip');
    expect(decision.limiting?.retryAfterMs).toBe(12_000);
  });

  it('passes the declared cost through to Redis', async () => {
    const redis = new FakeRedis();
    const costly: RateLimitPolicy = {
      name: 'test:costly',
      rationale: 'test',
      rules: [{ id: 'subject', algorithm: 'sliding-window', by: 'ip', windowMs: 1000, limit: 10, cost: 2 }],
    };
    await serviceWith(redis).check(costly, { ip: '1.1.1.1' });
    expect(redis.slidingCalls[0].cost).toBe(2);
  });
});

describe('RateLimitService — Redis failure', () => {
  it('falls back to the in-process limiter and marks the decision degraded', async () => {
    const redis = new FakeRedis();
    redis.available = false;

    const service = serviceWith(redis);
    const decision = await service.check(TWO_RULE_POLICY, { ip: '1.1.1.1' });

    expect(decision.allowed).toBe(true);
    expect(decision.degraded).toBe(true);
    expect(service.isDegraded).toBe(true);
  });

  it('the fallback STILL ENFORCES — fail-open is degraded, not off', async () => {
    // The single most important assertion about the outage path. If this were
    // wrong, a Redis blip would silently remove every limit in the system.
    const redis = new FakeRedis();
    redis.available = false;
    const service = serviceWith(redis);

    const policy: RateLimitPolicy = {
      name: 'test:strict',
      rationale: 'test',
      rules: [{ id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: 60_000, limit: 3 }],
    };

    const outcomes: boolean[] = [];
    for (let i = 0; i < 5; i += 1) {
      outcomes.push((await service.check(policy, { ip: '1.1.1.1' })).allowed);
    }

    expect(outcomes).toEqual([true, true, true, false, false]);
  });

  it('honours failOpen:false by denying rather than falling back', async () => {
    const redis = new FakeRedis();
    redis.available = false;

    const closed: RateLimitPolicy = {
      ...TWO_RULE_POLICY,
      name: 'test:fail-closed',
      failOpen: false,
    };

    const decision = await serviceWith(redis).check(closed, { ip: '1.1.1.1' });
    expect(decision.allowed).toBe(false);
    expect(decision.degraded).toBe(true);
  });

  it('never throws, whatever Redis does', async () => {
    // A limiter that can raise would be a NEW failure mode on the request
    // path, which is the opposite of its purpose.
    const redis = new FakeRedis();
    redis.slidingWindow = () => Promise.reject(new Error('connection reset'));

    await expect(
      serviceWith(redis).check(TWO_RULE_POLICY, { ip: '1.1.1.1' }),
    ).resolves.toBeDefined();
  });
});

describe('RateLimitService — policy resolution', () => {
  it('falls back to the default policy for an unknown or absent name', () => {
    const service = serviceWith(new FakeRedis());
    expect(service.resolvePolicy(undefined).name).toBe('default');
    expect(service.resolvePolicy('does-not-exist').name).toBe('default');
  });

  it('resolves a real policy by name', () => {
    const service = serviceWith(new FakeRedis());
    expect(service.resolvePolicy('otp:verify').name).toBe('otp:verify');
  });
});
