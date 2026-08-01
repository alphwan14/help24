import { Injectable, Logger } from '@nestjs/common';
import { createHash, randomUUID } from 'node:crypto';
import { RedisService } from '../../redis/redis.service';
import { LocalRateLimiter } from './local-rate-limiter';
import {
  DEFAULT_POLICY_NAME,
  POLICY_BY_NAME,
  validatePolicyCatalogue,
} from './rate-limit.policies';
import {
  LimitRule,
  RateLimitDecision,
  RateLimitPolicy,
  RuleDecision,
} from './rate-limit.types';

/** Everything the limiter needs to know about a request to make a decision. */
export interface RateLimitSubjectContext {
  readonly ip: string;
  readonly auth?: Record<string, unknown>;
  readonly body?: Record<string, unknown>;
  readonly query?: Record<string, unknown>;
  readonly params?: Record<string, unknown>;
}

/**
 * The rate-limiting engine.
 *
 * WHAT MAKES IT CORRECT ACROSS REPLICAS
 * -------------------------------------
 * All state lives in Redis, and each check-and-consume happens inside a single
 * Lua script, which Redis executes atomically. There is no read-decide-write
 * window for a second instance to interleave with, so the limit is a property
 * of the SYSTEM rather than of a process. This is the whole reason the layer
 * exists: the previous in-process limiter in routes.service.ts was correct for
 * exactly one replica and silently multiplied by the replica count thereafter.
 *
 * RULE EVALUATION IS SEQUENTIAL AND SHORT-CIRCUITS
 * ------------------------------------------------
 * Rules are evaluated in declaration order and stop at the first denial. That
 * ordering has a real consequence worth naming: budget is consumed as
 * evaluation proceeds, so a request denied by rule 2 has already spent a unit
 * of rule 1. Making all rules atomic together would need one script over
 * multiple keys with mixed algorithms — a significant increase in complexity
 * for an over-consumption of at most one unit on requests that are being
 * rejected anyway.
 *
 * The mitigation is the ordering convention (subject rules before IP rules,
 * enforced by the catalogue's own documentation): a heavy individual exhausts
 * their personal budget first and is stopped before they can spend the shared
 * IP budget that everyone else behind the same NAT depends on.
 *
 * IDENTITIES ARE HASHED BEFORE THEY BECOME KEYS
 * ---------------------------------------------
 * Keys contain a truncated SHA-256 of the identity, never the identity itself.
 * Two reasons: a Redis instance is a lower-trust store than the database, and
 * a `KEYS *` from anyone with access would otherwise enumerate user IDs and IP
 * addresses; and hashing bounds key length regardless of what a caller puts in
 * a `user_id` field.
 */
@Injectable()
export class RateLimitService {
  private readonly logger = new Logger(RateLimitService.name);
  private readonly local = new LocalRateLimiter();

  /** Rate-limit the "we are degraded" warning itself. */
  private lastDegradedLogAt = 0;
  private degradedRequestCount = 0;
  private static readonly DEGRADED_LOG_INTERVAL_MS = 30_000;

  constructor(private readonly redis: RedisService) {
    // A malformed catalogue must never reach production. Validating in the
    // constructor means a bad limit fails Nest's dependency resolution at
    // boot, which an orchestrator treats as a failed deploy.
    validatePolicyCatalogue();
  }

  /** True when decisions are currently coming from the in-process fallback. */
  get isDegraded(): boolean {
    return !this.redis.isAvailable;
  }

  resolvePolicy(name: string | undefined): RateLimitPolicy {
    if (!name) return POLICY_BY_NAME.get(DEFAULT_POLICY_NAME) as RateLimitPolicy;
    return (
      POLICY_BY_NAME.get(name) ?? (POLICY_BY_NAME.get(DEFAULT_POLICY_NAME) as RateLimitPolicy)
    );
  }

  /**
   * Evaluate `policy` against `context`, consuming budget.
   *
   * Never throws. A limiter that can raise would be a new failure mode on the
   * request path, which defeats its purpose — every internal error resolves to
   * the policy's fail-open decision instead.
   */
  async check(
    policy: RateLimitPolicy,
    context: RateLimitSubjectContext,
  ): Promise<RateLimitDecision> {
    const decisions: RuleDecision[] = [];
    let degraded = false;

    for (const rule of policy.rules) {
      const identity = this.resolveIdentity(rule, context);
      const key = this.buildKey(policy.name, rule.id, identity);

      let decision: RuleDecision;
      try {
        decision = await this.consumeRemote(key, rule);
      } catch (err) {
        degraded = true;
        this.noteDegraded(err);

        if (policy.failOpen === false) {
          // An explicit operator choice: this endpoint would rather be
          // unavailable than unmetered. No policy ships with this today —
          // the local fallback makes fail-open safe enough everywhere — but
          // the lever exists without a code change.
          return {
            allowed: false,
            policy: policy.name,
            limiting: {
              ruleId: rule.id,
              allowed: false,
              limit: limitOf(rule),
              remaining: 0,
              retryAfterMs: 1_000,
            },
            degraded: true,
          };
        }

        decision = this.local.consume(key, rule);
      }

      decisions.push(decision);
      if (!decision.allowed) {
        return { allowed: false, policy: policy.name, limiting: decision, degraded };
      }
    }

    return {
      allowed: true,
      policy: policy.name,
      // The tightest surviving rule shapes the headers, so a client watching
      // `RateLimit-Remaining` sees the constraint that will bite first rather
      // than the most permissive one.
      limiting: decisions.reduce<RuleDecision | null>(
        (tightest, current) =>
          tightest === null || current.remaining < tightest.remaining ? current : tightest,
        null,
      ),
      degraded,
    };
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  private async consumeRemote(key: string, rule: LimitRule): Promise<RuleDecision> {
    if (rule.algorithm === 'sliding-window') {
      const result = await this.redis.slidingWindow(
        key,
        rule.windowMs,
        rule.limit,
        rule.cost ?? 1,
        // Members of the sorted set must be unique or ZADD overwrites instead
        // of accumulating. A UUID per request guarantees that across every
        // instance without coordination.
        randomUUID(),
      );
      return { ruleId: rule.id, ...result };
    }

    const result = await this.redis.tokenBucket(
      key,
      rule.capacity,
      rule.refillTokens,
      rule.refillIntervalMs,
      rule.cost ?? 1,
    );
    return { ruleId: rule.id, ...result };
  }

  /**
   * Resolve the identity a rule counts against.
   *
   * A subject rule tries each declared path in order and takes the first
   * non-empty value. When none resolves — a caller omitted `user_id`, say —
   * it falls back to the IP, prefixed so it can never collide with a pure-IP
   * rule's key. Falling back rather than skipping matters: a rule that
   * silently stopped applying because a field was absent would be an
   * evasion technique (omit the field, escape the limit).
   */
  private resolveIdentity(rule: LimitRule, context: RateLimitSubjectContext): string {
    if (rule.by === 'ip') return `ip:${context.ip}`;

    for (const path of rule.by) {
      const value = readPath(context, path);
      if (typeof value === 'string' && value.trim() !== '') {
        return `${path}:${value.trim()}`;
      }
      if (typeof value === 'number') return `${path}:${value}`;
    }
    return `fallback-ip:${context.ip}`;
  }

  /**
   * `<prefix>:rl:<policy>:<rule>:<hash>`
   *
   * The prefix carries the environment (see redis.config.ts), so a staging
   * deployment sharing a Redis instance cannot consume production budget. 16
   * hex characters of SHA-256 is 64 bits — collision-implausible at any key
   * count this system will reach, and short enough to keep keys compact.
   */
  private buildKey(policy: string, ruleId: string, identity: string): string {
    const hash = createHash('sha256').update(identity).digest('hex').slice(0, 16);
    return `${this.redis.keyPrefix}:rl:${policy}:${ruleId}:${hash}`;
  }

  /**
   * Announce degradation once per interval, with a count of what it covered.
   *
   * Every request produces this error while Redis is down, so logging each
   * would bury the incident in its own noise — and an operator reading the log
   * during an outage needs the fact and its scale, not ten thousand copies of
   * the same line.
   */
  private noteDegraded(err: unknown): void {
    this.degradedRequestCount += 1;
    const now = Date.now();
    if (now - this.lastDegradedLogAt < RateLimitService.DEGRADED_LOG_INTERVAL_MS) return;

    const count = this.degradedRequestCount;
    this.lastDegradedLogAt = now;
    this.degradedRequestCount = 0;

    this.logger.warn(
      `[RATELIMIT] DEGRADED — Redis unavailable (${
        err instanceof Error ? err.message : String(err)
      }). Falling back to per-instance limits; ${count} request(s) affected in the ` +
        `last ${RateLimitService.DEGRADED_LOG_INTERVAL_MS / 1000}s. Limits are NOT ` +
        `shared across replicas while this persists.`,
    );
  }
}

function limitOf(rule: LimitRule): number {
  return rule.algorithm === 'sliding-window' ? rule.limit : rule.capacity;
}

/**
 * Read `auth.uid` / `body.user_id` / `query.user_id` / `params.postId` from the
 * request context.
 *
 * Deliberately one level deep. Deeper traversal would invite policies that
 * reach into nested payload structures, which couples a limit to a request
 * body's shape — a coupling that breaks silently when the shape changes. The
 * catalogue validator enforces the same restriction on the way in.
 */
function readPath(context: RateLimitSubjectContext, path: string): unknown {
  const [root, field] = path.split('.');
  const source =
    root === 'auth'
      ? context.auth
      : root === 'body'
        ? context.body
        : root === 'query'
          ? context.query
          : root === 'params'
            ? context.params
            : undefined;
  return source?.[field];
}
