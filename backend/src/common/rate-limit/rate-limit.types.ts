/**
 * Vocabulary for the rate limiter.
 *
 * A POLICY is what an endpoint declares. A RULE is one constraint inside it.
 * A policy with two rules ("5 per user per 10 minutes AND 60 per IP per 10
 * minutes") is denied if EITHER rule is exceeded — that combination is the
 * heart of the design, and the reason is worth stating precisely:
 *
 *   The per-subject rule expresses what a normal PERSON does. It is the number
 *   that has product meaning ("nobody legitimately pays for the same job six
 *   times in ten minutes").
 *
 *   The per-IP rule expresses what a normal MACHINE does. It is the one that
 *   still holds when the subject is spoofable — and on this API the subject is
 *   spoofable, because identity travels in the request body rather than in a
 *   verified token (see the security report). An attacker who rotates
 *   `user_id` escapes every subject rule and hits the IP rule instead.
 *
 * Neither is sufficient alone. Subject-only limits are trivially bypassed;
 * IP-only limits either punish shared connections or are too loose to matter.
 * Kenyan mobile carriers use carrier-grade NAT heavily, so a single public IP
 * can front hundreds of genuine Help24 users — which is exactly why every IP
 * rule below is sized for a crowd, and every subject rule for one person.
 */

/** Where the identity a rule counts against comes from. */
export type SubjectSource =
  /** The caller's network address. Always available; never spoofable at the
   *  TCP level, though shared by everyone behind the same NAT. */
  | 'ip'
  /**
   * An ordered list of context paths, first match wins. Supported roots:
   *   auth.uid      verified Firebase UID (trustworthy; usually absent today)
   *   body.<field>  asserted by the caller
   *   query.<field> asserted by the caller
   *   params.<field> a path segment, e.g. the post being acted on
   *
   * Falls back to the IP when nothing resolves, so a rule can never silently
   * become unenforced because a field was missing.
   */
  | string[];

interface RuleBase {
  /**
   * Stable identifier, unique within the policy. It becomes part of the Redis
   * key, so renaming one resets that rule's counters — which is a safe
   * operation, but not a silent one.
   */
  readonly id: string;
  readonly by: SubjectSource;
  /**
   * Units consumed per request. Above 1 for endpoints that are expensive or
   * that hand out something durable (a signed upload URL, an STK prompt on
   * someone's phone).
   */
  readonly cost?: number;
}

/**
 * Exact enforcement over a rolling window. O(n) memory in requests per window.
 * For low-volume, high-consequence endpoints where a fixed window's boundary
 * doubling would be unacceptable. See redis.scripts.ts.
 */
export interface SlidingWindowRule extends RuleBase {
  readonly algorithm: 'sliding-window';
  readonly windowMs: number;
  readonly limit: number;
}

/**
 * Burst-tolerant, O(1) memory. For high-volume endpoints where a mobile client
 * legitimately fires several requests at once on a screen open.
 * See redis.scripts.ts.
 */
export interface TokenBucketRule extends RuleBase {
  readonly algorithm: 'token-bucket';
  /** Maximum burst. */
  readonly capacity: number;
  /** Tokens returned every `refillIntervalMs` — the sustained rate. */
  readonly refillTokens: number;
  readonly refillIntervalMs: number;
}

export type LimitRule = SlidingWindowRule | TokenBucketRule;

export interface RateLimitPolicy {
  /** Referenced by `@RateLimit('name')` and reported in logs and headers. */
  readonly name: string;
  /** Why these numbers. Required — an unjustified limit is a magic constant. */
  readonly rationale: string;
  /**
   * Evaluated in order, short-circuiting on the first denial.
   *
   * Put subject rules BEFORE IP rules. Evaluation consumes budget as it goes,
   * so a denial by a later rule has already spent the earlier ones. Ordering
   * tight-subject-first means a single heavy user is stopped by their own
   * budget before they can spend the shared IP budget that everyone else
   * behind the same NAT depends on.
   */
  readonly rules: readonly LimitRule[];
  /**
   * What to do when Redis cannot answer. Defaults to true (allow).
   *
   * Fail-open is not "unlimited": the service falls back to an in-process
   * limiter applying the same policy per instance. The effective ceiling
   * during an outage is therefore `limit × instanceCount`, not infinity —
   * which is why fail-open is safe enough to be the default, and why the
   * honest bound is stated here rather than glossed over.
   */
  readonly failOpen?: boolean;
}

/** Outcome of evaluating one rule. */
export interface RuleDecision {
  readonly ruleId: string;
  readonly allowed: boolean;
  readonly limit: number;
  readonly remaining: number;
  readonly retryAfterMs: number;
}

/** Outcome of evaluating a whole policy. */
export interface RateLimitDecision {
  readonly allowed: boolean;
  readonly policy: string;
  /**
   * The rule that shaped the response headers: the denying rule when denied,
   * otherwise the one with the least remaining budget — so a client watching
   * `RateLimit-Remaining` sees the constraint that will actually bite first.
   */
  readonly limiting: RuleDecision | null;
  /** True when the answer came from the in-process fallback, not Redis. */
  readonly degraded: boolean;
}
