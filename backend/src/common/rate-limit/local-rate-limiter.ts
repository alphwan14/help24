import { LimitRule, RuleDecision } from './rate-limit.types';

/**
 * In-process fallback used only while Redis is unreachable.
 *
 * WHY THIS EXISTS
 * ---------------
 * "Fail open" is the right availability choice for a rate limiter — a Redis
 * blip must not become an API outage — but taken literally it means *no limit
 * at all* for the duration of the incident, which is when a system is least
 * able to absorb abuse. This class makes fail-open mean "degraded", not "off".
 *
 * THE HONEST BOUND IT PROVIDES
 * ----------------------------
 * State lives in one process, so with N backend instances the effective
 * ceiling becomes `limit × N` — a load balancer spreading an attacker's
 * requests across instances gives them N times the budget. With today's single
 * instance that is exactly the configured limit; at three instances an OTP
 * verify limit of 5/15min becomes 15/15min. Still bounded, still far short of
 * brute-forcing a 6-digit code, and vastly better than unlimited. State is
 * also lost on restart.
 *
 * That is the entire guarantee. It is written down here so nobody later reads
 * "fail open" in a policy and assumes either extreme.
 *
 * MEMORY IS BOUNDED BY CONSTRUCTION
 * ---------------------------------
 * An attacker rotating identities creates a new key per request, so an
 * unbounded map is a memory-exhaustion vector — the fallback would turn a
 * Redis outage into an OOM. Entries are swept on write and hard-capped; at the
 * cap the oldest are evicted, degrading to "some keys reset early" rather than
 * to a crash.
 */
export class LocalRateLimiter {
  private readonly windows = new Map<string, number[]>();
  private readonly buckets = new Map<string, { tokens: number; ts: number }>();

  /**
   * 50,000 keys ≈ a few megabytes at the observed sizes. Chosen to be large
   * enough that a real user population never evicts, and small enough that a
   * hostile one cannot exhaust a container's memory.
   */
  private static readonly MAX_KEYS = 50_000;

  /** Sweeping every call would be O(n) per request; every 500 amortises it. */
  private static readonly SWEEP_INTERVAL = 500;
  private writesSinceSweep = 0;

  /** Injected in tests so time can be controlled without waiting. */
  constructor(private readonly now: () => number = Date.now) {}

  consume(key: string, rule: LimitRule): RuleDecision {
    return rule.algorithm === 'sliding-window'
      ? this.consumeWindow(key, rule.windowMs, rule.limit, rule.cost ?? 1, rule.id)
      : this.consumeBucket(
          key,
          rule.capacity,
          rule.refillTokens,
          rule.refillIntervalMs,
          rule.cost ?? 1,
          rule.id,
        );
  }

  /** Number of tracked keys — asserted by tests, reported by diagnostics. */
  get size(): number {
    return this.windows.size + this.buckets.size;
  }

  /** Drop all state. Used when Redis recovers, and between tests. */
  clear(): void {
    this.windows.clear();
    this.buckets.clear();
    this.writesSinceSweep = 0;
  }

  private consumeWindow(
    key: string,
    windowMs: number,
    limit: number,
    cost: number,
    ruleId: string,
  ): RuleDecision {
    const now = this.now();
    const cutoff = now - windowMs;

    const hits = (this.windows.get(key) ?? []).filter((t) => t > cutoff);

    if (hits.length + cost > limit) {
      // Keep the trimmed list so the next call does not re-filter the same
      // expired entries, and so retryAfter is computed from live data.
      this.windows.set(key, hits);
      const oldest = hits[0];
      return {
        ruleId,
        allowed: false,
        limit,
        remaining: 0,
        retryAfterMs: oldest === undefined ? windowMs : Math.max(1, oldest + windowMs - now),
      };
    }

    for (let i = 0; i < cost; i += 1) hits.push(now);
    this.windows.set(key, hits);
    this.afterWrite(now);

    return { ruleId, allowed: true, limit, remaining: limit - hits.length, retryAfterMs: 0 };
  }

  private consumeBucket(
    key: string,
    capacity: number,
    refillTokens: number,
    refillIntervalMs: number,
    cost: number,
    ruleId: string,
  ): RuleDecision {
    const now = this.now();
    const state = this.buckets.get(key) ?? { tokens: capacity, ts: now };

    const elapsed = Math.max(0, now - state.ts);
    const tokens = Math.min(capacity, state.tokens + (elapsed / refillIntervalMs) * refillTokens);

    if (tokens < cost) {
      // Denied: state is deliberately left untouched, mirroring the Lua
      // script. Persisting the fractional balance on every rejection would
      // re-round it each time and the error accumulates — a caller hammering
      // a drained bucket would bank slightly less than the configured rate on
      // every attempt and end up permanently below it. Recomputing from a
      // stable anchor is one multiplication, and it is exact.
      //
      // (The Redis implementation still refreshes the key's TTL here, which is
      // the part that carries the enforcement guarantee. The in-process map
      // has no TTL, so there is nothing to refresh.)
      return {
        ruleId,
        allowed: false,
        limit: capacity,
        remaining: Math.floor(tokens),
        retryAfterMs: Math.ceil(((cost - tokens) / refillTokens) * refillIntervalMs),
      };
    }

    const remaining = tokens - cost;
    this.buckets.set(key, { tokens: remaining, ts: now });
    this.afterWrite(now);

    return {
      ruleId,
      allowed: true,
      limit: capacity,
      remaining: Math.floor(remaining),
      retryAfterMs: 0,
    };
  }

  private afterWrite(now: number): void {
    this.writesSinceSweep += 1;
    if (this.writesSinceSweep < LocalRateLimiter.SWEEP_INTERVAL) return;
    this.writesSinceSweep = 0;
    this.sweep(now);
  }

  /**
   * Evict dead keys, then hard-trim if still over the cap.
   *
   * A window is dead when every hit has aged out. A bucket is dead when it has
   * been idle long enough to have refilled completely — at that point it is
   * indistinguishable from a fresh one, so keeping it buys nothing. Bucket
   * entries do not record their own refill rate, so idleness is judged against
   * a conservative fixed horizon rather than a per-rule one; the hard cap
   * below is the real guarantee.
   */
  private sweep(now: number): void {
    const IDLE_HORIZON_MS = 60 * 60 * 1000;

    for (const [key, hits] of this.windows) {
      // A window's own length is unknown here, so an entry is only dropped
      // once its newest hit is older than the longest window in the catalogue
      // (one hour). Shorter windows self-trim on read.
      if (hits.length === 0 || hits[hits.length - 1] <= now - IDLE_HORIZON_MS) {
        this.windows.delete(key);
      }
    }
    for (const [key, state] of this.buckets) {
      if (state.ts <= now - IDLE_HORIZON_MS) this.buckets.delete(key);
    }

    this.trimTo(this.windows, LocalRateLimiter.MAX_KEYS / 2);
    this.trimTo(this.buckets, LocalRateLimiter.MAX_KEYS / 2);
  }

  /** Map preserves insertion order, so the first keys are the oldest. */
  private trimTo(map: Map<string, unknown>, max: number): void {
    if (map.size <= max) return;
    const excess = map.size - max;
    let removed = 0;
    for (const key of map.keys()) {
      map.delete(key);
      removed += 1;
      if (removed >= excess) break;
    }
  }
}
