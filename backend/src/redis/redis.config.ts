/**
 * Redis configuration — parsed and validated ONCE, at boot.
 *
 * WHY A DEDICATED PARSER RATHER THAN `ConfigService.get()` AT THE CALL SITE
 * ------------------------------------------------------------------------
 * A malformed REDIS_URL is not an error you want to discover on the first
 * rate-limited request at 2am. Every value the Redis layer will ever need is
 * resolved here, at startup, where a mistake is loud and immediate — and where
 * the failure message can say what to fix rather than surfacing as
 * `ECONNREFUSED ::1:6379` three layers down.
 *
 * WHY REDIS IS OPTIONAL RATHER THAN REQUIRED
 * ------------------------------------------
 * Making REDIS_URL mandatory would be the stricter choice, and it is wrong
 * here: this backend is already deployed and running WITHOUT Redis. A required
 * variable would turn the next deploy into an outage before the operator has
 * provisioned an instance. So an absent URL is a supported, degraded mode —
 * announced loudly at boot, reported by /health/redis, and visible in the
 * rate-limiter's own logs — never a silent one.
 *
 * When the operator is ready to make Redis load-bearing, `REDIS_REQUIRED=true`
 * flips it to fail-fast-at-boot. That is the flag to set in production once an
 * instance exists (see the QA checklist).
 */

/** Everything the Redis layer needs, fully resolved. */
export interface RedisConfig {
  /** `redis://` or `rediss://` connection string. Null = degraded mode. */
  readonly url: string | null;
  /** True when a missing/unreachable Redis should abort startup. */
  readonly required: boolean;
  /**
   * Prefix applied to EVERY key this backend writes.
   *
   * Defaults to `help24:<NODE_ENV>` because the likeliest Redis accident in a
   * small team is staging and production sharing one instance: without a
   * namespace, a staging load test would consume production rate-limit budget.
   * Overridable with REDIS_KEY_PREFIX when two deployments share a NODE_ENV.
   */
  readonly keyPrefix: string;
  /** TCP connect budget. Beyond this the connection attempt is abandoned. */
  readonly connectTimeoutMs: number;
  /**
   * Per-command budget. This is the number that bounds how long a Redis
   * problem can hold a user's HTTP request open, so it is deliberately small:
   * a rate-limit check that takes longer than this has already failed at its
   * job, which is to be cheap.
   */
  readonly commandTimeoutMs: number;
  /** Ceiling for the exponential reconnect backoff. */
  readonly maxReconnectDelayMs: number;
}

/** Thrown for configuration that cannot produce a working client. */
export class RedisConfigError extends Error {
  constructor(message: string) {
    super(`[Config][Redis] ${message}`);
    this.name = 'RedisConfigError';
  }
}

function intFromEnv(key: string, fallback: number, min: number, max: number): number {
  const raw = process.env[key]?.trim();
  if (!raw) return fallback;

  const value = Number(raw);
  if (!Number.isFinite(value) || !Number.isInteger(value)) {
    throw new RedisConfigError(`${key} must be an integer — got "${raw}".`);
  }
  if (value < min || value > max) {
    throw new RedisConfigError(`${key} must be between ${min} and ${max} — got ${value}.`);
  }
  return value;
}

function boolFromEnv(key: string, fallback: boolean): boolean {
  const raw = process.env[key]?.trim().toLowerCase();
  if (!raw) return fallback;
  if (['1', 'true', 'yes', 'on'].includes(raw)) return true;
  if (['0', 'false', 'no', 'off'].includes(raw)) return false;
  throw new RedisConfigError(`${key} must be a boolean (true/false) — got "${raw}".`);
}

/**
 * Validate the URL shape without connecting.
 *
 * Only the scheme and parseability are checked. Whether the host actually
 * answers is a runtime question that belongs to the health check, not to
 * configuration — a Redis that is merely restarting must not prevent boot.
 */
function parseUrl(raw: string): string {
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    throw new RedisConfigError(
      `REDIS_URL is not a valid URL — got "${redactUrl(raw)}". ` +
        `Expected redis://[:password@]host:port[/db] or rediss://… for TLS.`,
    );
  }

  if (parsed.protocol !== 'redis:' && parsed.protocol !== 'rediss:') {
    throw new RedisConfigError(
      `REDIS_URL must use the redis:// or rediss:// scheme — got "${parsed.protocol}//".`,
    );
  }
  if (!parsed.hostname) {
    throw new RedisConfigError('REDIS_URL has no host.');
  }
  return raw;
}

/**
 * Strip credentials from a connection string so it can be logged.
 *
 * REDIS_URL routinely embeds the password (`redis://:secret@host:6379`), and
 * boot logs are the first thing pasted into a bug report. Everything the Redis
 * layer prints about its own configuration goes through this.
 */
export function redactUrl(raw: string | null): string {
  if (!raw) return '(unset)';
  try {
    const parsed = new URL(raw);
    if (parsed.password) parsed.password = '***';
    if (parsed.username) parsed.username = '***';
    return parsed.toString();
  } catch {
    // Unparseable: reveal nothing beyond the scheme.
    const scheme = raw.split('://')[0];
    return scheme && scheme !== raw ? `${scheme}://***` : '***';
  }
}

export function loadRedisConfig(env: NodeJS.ProcessEnv = process.env): RedisConfig {
  const rawUrl = env.REDIS_URL?.trim();
  const required = boolFromEnv('REDIS_REQUIRED', false);

  if (!rawUrl) {
    if (required) {
      throw new RedisConfigError(
        'REDIS_REQUIRED=true but REDIS_URL is not set. Either provision Redis and ' +
          'set REDIS_URL, or unset REDIS_REQUIRED to run in degraded (per-instance) mode.',
      );
    }
    return {
      url: null,
      required,
      keyPrefix: defaultKeyPrefix(env),
      connectTimeoutMs: intFromEnv('REDIS_CONNECT_TIMEOUT_MS', 5_000, 100, 60_000),
      commandTimeoutMs: intFromEnv('REDIS_COMMAND_TIMEOUT_MS', 250, 25, 10_000),
      maxReconnectDelayMs: intFromEnv('REDIS_MAX_RECONNECT_DELAY_MS', 10_000, 100, 120_000),
    };
  }

  return {
    url: parseUrl(rawUrl),
    required,
    keyPrefix: defaultKeyPrefix(env),
    connectTimeoutMs: intFromEnv('REDIS_CONNECT_TIMEOUT_MS', 5_000, 100, 60_000),
    // 250ms: a local or same-region Redis answers a rate-limit script in well
    // under 5ms. Anything approaching a quarter-second means the dependency is
    // sick, and the correct response is to stop waiting and fall back — not to
    // make every user wait for a limiter that is supposed to be invisible.
    commandTimeoutMs: intFromEnv('REDIS_COMMAND_TIMEOUT_MS', 250, 25, 10_000),
    maxReconnectDelayMs: intFromEnv('REDIS_MAX_RECONNECT_DELAY_MS', 10_000, 100, 120_000),
  };
}

function defaultKeyPrefix(env: NodeJS.ProcessEnv): string {
  const explicit = env.REDIS_KEY_PREFIX?.trim();
  if (explicit) return explicit.endsWith(':') ? explicit.slice(0, -1) : explicit;
  const nodeEnv = env.NODE_ENV?.trim() || 'development';
  return `help24:${nodeEnv}`;
}
