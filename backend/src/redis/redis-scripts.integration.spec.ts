import { randomUUID } from 'node:crypto';
import { RedisService } from './redis.service';
import { RedisConfig } from './redis.config';

/**
 * INTEGRATION — runs the real Lua scripts against a real Redis server.
 *
 * OPT-IN BY DESIGN
 * ----------------
 * This suite is skipped unless REDIS_TEST_URL is set. That is deliberate
 * rather than convenient: a suite that silently passes when its dependency is
 * missing is worse than no suite at all, because it reports success for
 * something it never checked. With the variable set, every failure here is a
 * real failure.
 *
 *   REDIS_TEST_URL=redis://127.0.0.1:6379 npx jest redis-scripts.integration
 *
 * WHY THIS CANNOT BE A UNIT TEST
 * ------------------------------
 * The scripts' two most important properties — atomicity under concurrency,
 * and using the SERVER's clock rather than the caller's — only exist inside
 * Redis. A mock would assert the behaviour of the mock. The concurrency case
 * below is the single most valuable test in the codebase for this phase: it is
 * the direct evidence that limits hold when more than one caller (or more than
 * one backend replica) is in flight at the same instant.
 */

const TEST_URL = process.env.REDIS_TEST_URL;
const describeIntegration = TEST_URL ? describe : describe.skip;

if (!TEST_URL) {
  // eslint-disable-next-line no-console
  console.warn(
    '\n[redis-scripts.integration] SKIPPED — set REDIS_TEST_URL to run the Lua ' +
      'scripts against a live Redis (e.g. REDIS_TEST_URL=redis://127.0.0.1:6379).\n',
  );
}

function testConfig(): RedisConfig {
  return {
    url: TEST_URL ?? null,
    required: true,
    keyPrefix: `help24:itest:${randomUUID().slice(0, 8)}`,
    connectTimeoutMs: 5_000,
    // Generous: a laptop running Redis in WSL under load should not produce a
    // flaky failure that looks like a logic bug.
    commandTimeoutMs: 5_000,
    maxReconnectDelayMs: 1_000,
  };
}

describeIntegration('Lua scripts against a live Redis', () => {
  let redis: RedisService;
  let prefix: string;

  beforeAll(async () => {
    const config = testConfig();
    prefix = config.keyPrefix;
    redis = new RedisService(config);
    await redis.onModuleInit();
    expect(redis.isAvailable).toBe(true);
  });

  afterAll(async () => {
    if (redis) await redis.onApplicationShutdown();
  });

  /** A fresh, uniquely-named key per test — no cross-test interference. */
  const key = (label: string): string => `${prefix}:${label}:${randomUUID()}`;

  // ── Sliding window ────────────────────────────────────────────────────────

  describe('sliding window', () => {
    it('allows exactly `limit` and then denies', async () => {
      const k = key('sw-basic');
      const outcomes: boolean[] = [];
      for (let i = 0; i < 6; i += 1) {
        outcomes.push((await redis.slidingWindow(k, 60_000, 4, 1, randomUUID())).allowed);
      }
      expect(outcomes).toEqual([true, true, true, true, false, false]);
    });

    it('reports remaining budget accurately', async () => {
      const k = key('sw-remaining');
      expect((await redis.slidingWindow(k, 60_000, 3, 1, randomUUID())).remaining).toBe(2);
      expect((await redis.slidingWindow(k, 60_000, 3, 1, randomUUID())).remaining).toBe(1);
      expect((await redis.slidingWindow(k, 60_000, 3, 1, randomUUID())).remaining).toBe(0);
    });

    it('returns a retryAfter bounded by the window', async () => {
      const k = key('sw-retry');
      await redis.slidingWindow(k, 2_000, 1, 1, randomUUID());
      const denied = await redis.slidingWindow(k, 2_000, 1, 1, randomUUID());
      expect(denied.allowed).toBe(false);
      expect(denied.retryAfterMs).toBeGreaterThan(0);
      expect(denied.retryAfterMs).toBeLessThanOrEqual(2_000);
    });

    it('genuinely slides — budget returns as entries age out', async () => {
      const k = key('sw-slide');
      await redis.slidingWindow(k, 700, 2, 1, randomUUID());
      await redis.slidingWindow(k, 700, 2, 1, randomUUID());
      expect((await redis.slidingWindow(k, 700, 2, 1, randomUUID())).allowed).toBe(false);

      await new Promise((resolve) => setTimeout(resolve, 800));
      expect((await redis.slidingWindow(k, 700, 2, 1, randomUUID())).allowed).toBe(true);
    });

    it('honours cost > 1', async () => {
      const k = key('sw-cost');
      expect((await redis.slidingWindow(k, 60_000, 4, 3, randomUUID())).allowed).toBe(true);
      expect((await redis.slidingWindow(k, 60_000, 4, 3, randomUUID())).allowed).toBe(false);
    });

    it('sets a TTL so abandoned keys evict themselves', async () => {
      // Without this, every unique identity ever seen would live in Redis
      // forever and memory would grow without bound.
      const k = key('sw-ttl');
      await redis.slidingWindow(k, 5_000, 3, 1, randomUUID());
      const ttl = await rawTtl(redis, k);
      expect(ttl).toBeGreaterThan(0);
      expect(ttl).toBeLessThanOrEqual(5_000);
    });

    it('IS ATOMIC — concurrent callers cannot exceed the limit', async () => {
      // THE test. Read-decide-write across a network would let two callers
      // both observe 4/5 and both proceed. This is the direct evidence that
      // the limit is a property of the system rather than of one process, and
      // therefore that it survives horizontal scaling.
      const k = key('sw-atomic');
      const LIMIT = 10;

      const results = await Promise.all(
        Array.from({ length: 100 }, () => redis.slidingWindow(k, 60_000, LIMIT, 1, randomUUID())),
      );

      expect(results.filter((r) => r.allowed)).toHaveLength(LIMIT);
    });
  });

  // ── Token bucket ──────────────────────────────────────────────────────────

  describe('token bucket', () => {
    it('starts full, so a first-time caller is never penalised', async () => {
      const k = key('tb-fresh');
      for (let i = 0; i < 5; i += 1) {
        expect((await redis.tokenBucket(k, 5, 5, 60_000, 1)).allowed).toBe(true);
      }
      expect((await redis.tokenBucket(k, 5, 5, 60_000, 1)).allowed).toBe(false);
    });

    it('refills over time', async () => {
      const k = key('tb-refill');
      // capacity 2, refilling 2 tokens per 400ms.
      await redis.tokenBucket(k, 2, 2, 400, 1);
      await redis.tokenBucket(k, 2, 2, 400, 1);
      expect((await redis.tokenBucket(k, 2, 2, 400, 1)).allowed).toBe(false);

      await new Promise((resolve) => setTimeout(resolve, 450));
      expect((await redis.tokenBucket(k, 2, 2, 400, 1)).allowed).toBe(true);
    });

    it('never exceeds capacity however long it idles', async () => {
      const k = key('tb-cap');
      await redis.tokenBucket(k, 3, 3, 100, 1);
      await new Promise((resolve) => setTimeout(resolve, 400)); // 12 tokens' worth

      let allowed = 0;
      for (let i = 0; i < 10; i += 1) {
        if ((await redis.tokenBucket(k, 3, 3, 100_000, 1)).allowed) allowed += 1;
      }
      expect(allowed).toBeLessThanOrEqual(3);
    });

    it('refreshes the TTL on a DENIED request, closing the expiry bypass', async () => {
      // If a rejected request did not refresh the TTL, a caller hammering a
      // drained bucket would let the key expire mid-attack and the next
      // request would start from a FULL bucket — a complete bypass for anyone
      // who simply does not back off.
      const k = key('tb-ttl-refresh');
      // capacity 1, refill 1 per 400ms → TTL = 400 + 400 = 800ms.
      await redis.tokenBucket(k, 1, 1, 400, 1);

      await new Promise((resolve) => setTimeout(resolve, 200));
      const denied = await redis.tokenBucket(k, 1, 1, 400, 1);
      expect(denied.allowed).toBe(false);

      const ttlAfterDenial = await rawTtl(redis, k);
      // A denial has just re-armed the full 800ms, so more than the ~600ms
      // that would remain if only the original write had set it.
      expect(ttlAfterDenial).toBeGreaterThan(650);
    });

    it('IS ATOMIC — concurrent callers cannot exceed capacity', async () => {
      const k = key('tb-atomic');
      const CAPACITY = 8;

      const results = await Promise.all(
        Array.from({ length: 80 }, () => redis.tokenBucket(k, CAPACITY, CAPACITY, 60_000, 1)),
      );

      expect(results.filter((r) => r.allowed)).toHaveLength(CAPACITY);
    });
  });

  // ── Server behaviour the scripts depend on ───────────────────────────────

  describe('server contract', () => {
    it('runs on Redis 5 or newer, as the TIME-then-write scripts require', async () => {
      const info = await rawInfo(redis);
      const version = /redis_version:([^\r\n]+)/.exec(info)?.[1]?.trim();
      expect(version).toBeDefined();
      expect(Number(version!.split('.')[0])).toBeGreaterThanOrEqual(5);
    });

    it('answers PING through the health probe', async () => {
      const ping = await redis.ping();
      expect(ping.ok).toBe(true);
      expect(ping.latencyMs).not.toBeNull();
    });

    it('uses the SERVER clock, not the caller clock', async () => {
      // If the scripts trusted a client-supplied timestamp, a replica with a
      // skewed clock could evict another replica's still-valid entries and
      // silently hand out extra budget. Moving the local clock must change
      // nothing, because the caller's clock is never consulted.
      const k = key('server-clock');
      const realNow = Date.now;
      try {
        Date.now = () => realNow() + 60 * 60 * 1000; // pretend to be an hour ahead
        await redis.slidingWindow(k, 60_000, 2, 1, randomUUID());
        await redis.slidingWindow(k, 60_000, 2, 1, randomUUID());
        expect((await redis.slidingWindow(k, 60_000, 2, 1, randomUUID())).allowed).toBe(false);
      } finally {
        Date.now = realNow;
      }
    });
  });
});

/** Reach past the service's narrow surface for assertions only tests need. */
async function rawTtl(redis: RedisService, key: string): Promise<number> {
  const client = (redis as unknown as { client: { pttl(k: string): Promise<number> } }).client;
  return client.pttl(key);
}

async function rawInfo(redis: RedisService): Promise<string> {
  const client = (redis as unknown as { client: { info(s: string): Promise<string> } }).client;
  return client.info('server');
}
