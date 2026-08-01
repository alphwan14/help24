/**
 * Health vocabulary.
 *
 * Three states, not two, because "up or down" cannot express the situation
 * that actually occurs most often in production: the dependency answers, but
 * badly. A Supabase that responds in four seconds is not healthy and is not
 * down — and the difference decides whether someone is woken up.
 *
 *   healthy      answered correctly, within its latency budget
 *   degraded     answered, but slowly; or is absent in a way the system is
 *                designed to tolerate (Redis unconfigured → per-instance rate
 *                limits still work, just weaker)
 *   unavailable  did not answer, or answered wrongly
 */
export type DependencyStatus = 'healthy' | 'degraded' | 'unavailable';

export interface DependencyHealth {
  readonly name: string;
  readonly status: DependencyStatus;
  /** Round-trip time of the probe. Null when no call was made. */
  readonly latencyMs: number | null;
  /** Human-readable explanation. Always present for non-healthy states. */
  readonly detail?: string;
  /** Non-secret facts useful when diagnosing (connection status, host, …). */
  readonly meta?: Record<string, unknown>;
  /** When this result was produced. */
  readonly checkedAt: string;
}

/**
 * Latency budgets.
 *
 * Each is the point beyond which the dependency is materially hurting user
 * experience, not an arbitrary round number:
 *
 *   Redis      the rate limiter runs on every request and its command timeout
 *              is 250ms. A ping above 100ms means the limiter is already
 *              eating a meaningful slice of every request's budget.
 *   Database   Supabase is a network hop away and a simple indexed read is
 *              tens of milliseconds in the same region. 750ms means something
 *              is wrong upstream — connection saturation, or a cross-region
 *              hop — well before it becomes a visible stall.
 *   Firebase   only consulted when sending a push, and the SDK caches its
 *              access token for an hour, so latency here is off the request
 *              path entirely. The budget is loose accordingly.
 */
export const LATENCY_BUDGET_MS = {
  redis: 100,
  database: 750,
  firebase: 2_000,
} as const;

/**
 * How long each probe is allowed to take before it is abandoned and reported
 * as unavailable. A health check that can hang is not a health check — it is
 * the thing that makes an incident worse, because the monitor stops answering
 * at exactly the moment it is needed.
 */
export const PROBE_TIMEOUT_MS = {
  redis: 1_000,
  database: 3_000,
  firebase: 5_000,
} as const;
