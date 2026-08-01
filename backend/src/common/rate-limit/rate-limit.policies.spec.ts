import {
  DEFAULT_POLICY_NAME,
  POLICY_BY_NAME,
  RATE_LIMIT_POLICIES,
  validatePolicyCatalogue,
} from './rate-limit.policies';
import { RateLimitPolicy } from './rate-limit.types';

/**
 * The catalogue is configuration, and configuration mistakes here are silent:
 * a broken policy does not crash anything, it just protects the wrong amount.
 * These tests are the compiler for that configuration.
 */
describe('the shipped catalogue', () => {
  it('passes its own validator', () => {
    expect(() => validatePolicyCatalogue()).not.toThrow();
  });

  it('defines a default policy, because undecorated routes fall back to it', () => {
    expect(POLICY_BY_NAME.has(DEFAULT_POLICY_NAME)).toBe(true);
  });

  it('gives every policy a rationale — an unexplained limit is a magic constant', () => {
    for (const policy of RATE_LIMIT_POLICIES) {
      expect(policy.rationale.length).toBeGreaterThan(40);
    }
  });

  it('orders subject rules before IP rules in every policy', () => {
    // Evaluation consumes budget as it proceeds and short-circuits on the
    // first denial. Subject-first means a heavy individual exhausts their own
    // budget before spending the shared IP budget everyone behind the same
    // NAT depends on. An out-of-order policy silently inverts that.
    for (const policy of RATE_LIMIT_POLICIES) {
      const firstIpIndex = policy.rules.findIndex((r) => r.by === 'ip');
      const lastSubjectIndex = policy.rules.reduce(
        (last, rule, index) => (rule.by !== 'ip' ? index : last),
        -1,
      );
      if (firstIpIndex !== -1 && lastSubjectIndex !== -1) {
        expect(lastSubjectIndex).toBeLessThan(firstIpIndex);
      }
    }
  });

  it('keeps every IP rule at least as permissive as its subject rule', () => {
    // Kenyan carriers use CGNAT heavily: hundreds of genuine users can share
    // one address. An IP rule tighter than the per-person rule would make the
    // shared limit bite before the individual one, throttling a neighbourhood
    // because one person was busy.
    for (const policy of RATE_LIMIT_POLICIES) {
      const subject = policy.rules.find((r) => r.by !== 'ip');
      const ip = policy.rules.find((r) => r.by === 'ip');
      if (!subject || !ip) continue;

      expect(ratePerMinute(ip)).toBeGreaterThanOrEqual(ratePerMinute(subject));
    }
  });

  it('protects the OTP verify path with a genuinely tight ceiling', () => {
    // A 6-digit code valid for 5 minutes. The whole security of the payout
    // number change rests on this number, so it is asserted explicitly rather
    // than left to a general rule.
    const policy = POLICY_BY_NAME.get('otp:verify') as RateLimitPolicy;
    const perProvider = policy.rules.find((r) => r.id === 'provider');
    const perIp = policy.rules.find((r) => r.id === 'ip');

    expect(perProvider).toMatchObject({ algorithm: 'sliding-window', limit: 5 });
    // The IP rule is the one that matters, because provider_id is caller-
    // supplied and can be rotated. It must keep guesses to the low tens per
    // hour — a rounding error against a million-value keyspace.
    expect(ratePerMinute(perIp!)).toBeLessThanOrEqual(1);
  });

  it('keeps every money-moving endpoint on an exact algorithm, not a bucket', () => {
    // A token bucket tolerates bursts by design. For STK pushes, payouts and
    // OTP checks, the burst IS the abuse.
    for (const name of ['payments:initiate', 'payments:release', 'otp:verify', 'otp:issue']) {
      const policy = POLICY_BY_NAME.get(name) as RateLimitPolicy;
      for (const rule of policy.rules) {
        expect(rule.algorithm).toBe('sliding-window');
      }
    }
  });

  it('keeps the payment callback policy the loosest of all', () => {
    // Deliberate: dropping a genuine Daraja callback means a payment that
    // never settles. If a future edit tightens this below a normal read
    // endpoint, that trade-off has been reversed by accident.
    const callback = POLICY_BY_NAME.get('payments:callback') as RateLimitPolicy;
    const feed = POLICY_BY_NAME.get('feed:read') as RateLimitPolicy;

    const callbackIp = callback.rules.find((r) => r.by === 'ip')!;
    const feedIp = feed.rules.find((r) => r.by === 'ip')!;
    expect(ratePerMinute(callbackIp)).toBeGreaterThanOrEqual(ratePerMinute(feedIp));
  });

  it('caps the unauthenticated STK smoke-test endpoint hard', () => {
    const policy = POLICY_BY_NAME.get('payments:smoke') as RateLimitPolicy;
    expect(ratePerMinute(policy.rules[0])).toBeLessThanOrEqual(0.05); // 3/hour
  });

  it('preserves the pre-existing Google Routes ceiling exactly', () => {
    // Changing a limit at the same time as changing where it is enforced
    // would confound any comparison of before and after.
    const policy = POLICY_BY_NAME.get('routes:compute') as RateLimitPolicy;
    expect(policy.rules[0]).toMatchObject({
      algorithm: 'sliding-window',
      by: 'ip',
      windowMs: 600_000,
      limit: 40,
    });
  });
});

describe('validatePolicyCatalogue', () => {
  const base = { id: 'ip', by: 'ip' as const };

  it('rejects duplicate policy names', () => {
    const policy: RateLimitPolicy = {
      name: 'dupe',
      rationale: 'x'.repeat(50),
      rules: [{ ...base, algorithm: 'sliding-window', windowMs: 1000, limit: 5 }],
    };
    expect(() => validatePolicyCatalogue([defaultPolicy(), policy, policy])).toThrow(/Duplicate policy/);
  });

  it('rejects duplicate rule ids — they would share a Redis key', () => {
    expect(() =>
      validatePolicyCatalogue([
        defaultPolicy(),
        {
          name: 'p',
          rationale: 'x'.repeat(50),
          rules: [
            { ...base, algorithm: 'sliding-window', windowMs: 1000, limit: 5 },
            { ...base, algorithm: 'sliding-window', windowMs: 2000, limit: 9 },
          ],
        },
      ]),
    ).toThrow(/duplicate rule id/);
  });

  it('rejects a policy with no rules — it would allow everything', () => {
    expect(() =>
      validatePolicyCatalogue([defaultPolicy(), { name: 'p', rationale: 'x'.repeat(50), rules: [] }]),
    ).toThrow(/no rules/);
  });

  it('rejects a cost that exceeds its own limit — every request would 429', () => {
    expect(() =>
      validatePolicyCatalogue([
        defaultPolicy(),
        {
          name: 'p',
          rationale: 'x'.repeat(50),
          rules: [{ ...base, algorithm: 'sliding-window', windowMs: 1000, limit: 2, cost: 5 }],
        },
      ]),
    ).toThrow(/exceeds limit/);
  });

  it('rejects an unsupported subject path', () => {
    expect(() =>
      validatePolicyCatalogue([
        defaultPolicy(),
        {
          name: 'p',
          rationale: 'x'.repeat(50),
          rules: [
            {
              id: 'subject',
              by: ['headers.x-user'],
              algorithm: 'sliding-window',
              windowMs: 1000,
              limit: 5,
            },
          ],
        },
      ]),
    ).toThrow(/unsupported subject path/);
  });

  it('rejects a catalogue with no default policy', () => {
    expect(() =>
      validatePolicyCatalogue([
        {
          name: 'p',
          rationale: 'x'.repeat(50),
          rules: [{ ...base, algorithm: 'sliding-window', windowMs: 1000, limit: 5 }],
        },
      ]),
    ).toThrow(/must define a "default" policy/);
  });
});

function defaultPolicy(): RateLimitPolicy {
  return {
    name: DEFAULT_POLICY_NAME,
    rationale: 'x'.repeat(50),
    rules: [{ id: 'ip', by: 'ip', algorithm: 'sliding-window', windowMs: 1000, limit: 5 }],
  };
}

/** Normalise both algorithms to a comparable sustained requests-per-minute. */
function ratePerMinute(rule: RateLimitPolicy['rules'][number]): number {
  return rule.algorithm === 'sliding-window'
    ? (rule.limit / rule.windowMs) * 60_000
    : (rule.refillTokens / rule.refillIntervalMs) * 60_000;
}
