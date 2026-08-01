import { LocalRateLimiter } from './local-rate-limiter';
import { SlidingWindowRule, TokenBucketRule } from './rate-limit.types';

/**
 * The fallback is what makes "fail open" mean "degraded" rather than "off",
 * so it has to enforce genuinely — a fallback that quietly allowed everything
 * would be worse than none, because it would look like protection.
 */
describe('LocalRateLimiter — sliding window', () => {
  const rule: SlidingWindowRule = {
    id: 'subject',
    algorithm: 'sliding-window',
    by: ['body.user_id'],
    windowMs: 1_000,
    limit: 3,
  };

  let now = 1_000_000;
  let limiter: LocalRateLimiter;

  beforeEach(() => {
    now = 1_000_000;
    limiter = new LocalRateLimiter(() => now);
  });

  it('allows exactly `limit` requests and denies the next', () => {
    expect(limiter.consume('k', rule).allowed).toBe(true);
    expect(limiter.consume('k', rule).allowed).toBe(true);
    expect(limiter.consume('k', rule).allowed).toBe(true);
    expect(limiter.consume('k', rule).allowed).toBe(false);
  });

  it('reports remaining budget accurately', () => {
    expect(limiter.consume('k', rule).remaining).toBe(2);
    expect(limiter.consume('k', rule).remaining).toBe(1);
    expect(limiter.consume('k', rule).remaining).toBe(0);
  });

  it('slides — budget returns as the oldest entries age out, not all at once', () => {
    // The property a fixed window does not have. Three requests at t=0, then
    // one at t=500 must still be denied; only after the first three leave the
    // window (t>1000) does budget return.
    limiter.consume('k', rule);
    limiter.consume('k', rule);
    limiter.consume('k', rule);

    now += 500;
    expect(limiter.consume('k', rule).allowed).toBe(false);

    now += 501;
    expect(limiter.consume('k', rule).allowed).toBe(true);
  });

  it('reports a retryAfter that actually reflects when budget frees', () => {
    limiter.consume('k', rule);
    now += 200;
    limiter.consume('k', rule);
    limiter.consume('k', rule);

    const denied = limiter.consume('k', rule);
    expect(denied.allowed).toBe(false);
    // The oldest hit was at t=0 and the window is 1000ms; we are at t=200.
    expect(denied.retryAfterMs).toBe(800);
  });

  it('keys are independent', () => {
    for (let i = 0; i < 3; i += 1) limiter.consume('a', rule);
    expect(limiter.consume('a', rule).allowed).toBe(false);
    expect(limiter.consume('b', rule).allowed).toBe(true);
  });

  it('honours cost > 1', () => {
    const costly: SlidingWindowRule = { ...rule, cost: 3 };
    expect(limiter.consume('k', costly).allowed).toBe(true);
    expect(limiter.consume('k', costly).allowed).toBe(false);
  });
});

describe('LocalRateLimiter — token bucket', () => {
  const rule: TokenBucketRule = {
    id: 'subject',
    algorithm: 'token-bucket',
    by: 'ip',
    capacity: 10,
    refillTokens: 10,
    refillIntervalMs: 1_000,
  };

  let now = 1_000_000;
  let limiter: LocalRateLimiter;

  beforeEach(() => {
    now = 1_000_000;
    limiter = new LocalRateLimiter(() => now);
  });

  it('starts full, so a first-time caller is never penalised', () => {
    for (let i = 0; i < 10; i += 1) expect(limiter.consume('k', rule).allowed).toBe(true);
    expect(limiter.consume('k', rule).allowed).toBe(false);
  });

  it('refills proportionally to elapsed time', () => {
    for (let i = 0; i < 10; i += 1) limiter.consume('k', rule);
    expect(limiter.consume('k', rule).allowed).toBe(false);

    now += 300; // 30% of the interval → 3 tokens
    expect(limiter.consume('k', rule).allowed).toBe(true);
    expect(limiter.consume('k', rule).allowed).toBe(true);
    expect(limiter.consume('k', rule).allowed).toBe(true);
    expect(limiter.consume('k', rule).allowed).toBe(false);
  });

  it('never refills beyond capacity', () => {
    limiter.consume('k', rule);
    now += 60_000; // an hour of refill for a 10-token bucket
    for (let i = 0; i < 10; i += 1) expect(limiter.consume('k', rule).allowed).toBe(true);
    expect(limiter.consume('k', rule).allowed).toBe(false);
  });

  it('sustained hammering on a drained bucket yields exactly the refill rate', () => {
    // The property that matters against an attacker who does not back off:
    // once drained, hammering must earn the refill rate and not one token
    // more, no matter how many attempts are made in between. This is the
    // observable consequence of persisting state on the DENIED path as well
    // as the allowed one.
    for (let i = 0; i < 10; i += 1) limiter.consume('k', rule);

    let allowed = 0;
    // 100 attempts spread across exactly one refill interval.
    for (let i = 0; i < 100; i += 1) {
      now += 10;
      if (limiter.consume('k', rule).allowed) allowed += 1;
    }

    expect(allowed).toBe(10); // refillTokens per refillIntervalMs — exactly.
  });

  it('does not drain the bucket when the clock steps backwards', () => {
    limiter.consume('k', rule);
    now -= 5_000; // NTP correction
    expect(limiter.consume('k', rule).allowed).toBe(true);
  });

  it('reports a retryAfter proportional to the deficit', () => {
    for (let i = 0; i < 10; i += 1) limiter.consume('k', rule);
    const denied = limiter.consume('k', rule);
    expect(denied.allowed).toBe(false);
    expect(denied.retryAfterMs).toBe(100); // 1 token at 10/sec
  });
});

describe('LocalRateLimiter — memory bounds', () => {
  it('does not grow without limit under identity rotation', () => {
    // The attack this defends against: during a Redis outage, an attacker
    // rotating user ids would create one key per request. An unbounded map
    // would turn a Redis incident into an out-of-memory crash.
    let now = 1_000_000;
    const limiter = new LocalRateLimiter(() => now);
    const rule: SlidingWindowRule = {
      id: 'subject',
      algorithm: 'sliding-window',
      by: ['body.user_id'],
      windowMs: 1_000,
      limit: 5,
    };

    for (let i = 0; i < 60_000; i += 1) {
      limiter.consume(`key-${i}`, rule);
      now += 1; // each key ages out quickly
    }

    expect(limiter.size).toBeLessThanOrEqual(50_000);
  });

  it('clear() drops all state', () => {
    const limiter = new LocalRateLimiter();
    limiter.consume('k', {
      id: 'r',
      algorithm: 'token-bucket',
      by: 'ip',
      capacity: 2,
      refillTokens: 1,
      refillIntervalMs: 1_000,
    });
    expect(limiter.size).toBe(1);
    limiter.clear();
    expect(limiter.size).toBe(0);
  });
});
