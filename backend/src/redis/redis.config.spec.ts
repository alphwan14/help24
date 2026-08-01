import { loadRedisConfig, RedisConfigError, redactUrl } from './redis.config';

/** A clean environment for each case — these functions read process.env. */
function env(overrides: Record<string, string | undefined>): NodeJS.ProcessEnv {
  return { NODE_ENV: 'test', ...overrides } as NodeJS.ProcessEnv;
}

describe('loadRedisConfig', () => {
  const original = { ...process.env };
  afterEach(() => {
    process.env = { ...original };
  });

  it('treats an absent REDIS_URL as a supported degraded mode', () => {
    // Making it required would turn the next deploy of an already-running
    // service into an outage before Redis has been provisioned.
    const config = loadRedisConfig(env({}));
    expect(config.url).toBeNull();
    expect(config.required).toBe(false);
  });

  it('throws when REDIS_REQUIRED=true but no URL is set', () => {
    process.env.REDIS_REQUIRED = 'true';
    expect(() => loadRedisConfig(env({}))).toThrow(RedisConfigError);
  });

  it('accepts redis:// and rediss:// URLs', () => {
    expect(loadRedisConfig(env({ REDIS_URL: 'redis://localhost:6379' })).url).toBeTruthy();
    expect(loadRedisConfig(env({ REDIS_URL: 'rediss://user:pw@host:6380/2' })).url).toBeTruthy();
  });

  it('rejects a non-Redis scheme with an actionable message', () => {
    expect(() => loadRedisConfig(env({ REDIS_URL: 'http://localhost:6379' }))).toThrow(
      /redis:\/\/ or rediss:\/\//,
    );
  });

  it('rejects an unparseable URL', () => {
    expect(() => loadRedisConfig(env({ REDIS_URL: 'not a url' }))).toThrow(RedisConfigError);
  });

  it('never echoes the password when reporting a bad URL', () => {
    // Boot errors are the first thing pasted into a bug report.
    try {
      loadRedisConfig(env({ REDIS_URL: 'ftp://:sup3rs3cret@host:6379' }));
      throw new Error('should have thrown');
    } catch (err) {
      expect(String(err)).not.toContain('sup3rs3cret');
    }
  });

  it('namespaces keys by NODE_ENV so environments cannot share budget', () => {
    // The likeliest Redis accident in a small team is staging and production
    // pointed at the same instance.
    expect(loadRedisConfig(env({ NODE_ENV: 'production' })).keyPrefix).toBe('help24:production');
    expect(loadRedisConfig(env({ NODE_ENV: 'development' })).keyPrefix).toBe('help24:development');
  });

  it('honours an explicit REDIS_KEY_PREFIX and strips a trailing colon', () => {
    expect(loadRedisConfig(env({ REDIS_KEY_PREFIX: 'help24:staging:' })).keyPrefix).toBe(
      'help24:staging',
    );
  });

  it('defaults the command timeout low, because the limiter must stay invisible', () => {
    expect(loadRedisConfig(env({})).commandTimeoutMs).toBe(250);
  });

  it('rejects a non-numeric or out-of-range timeout', () => {
    process.env.REDIS_COMMAND_TIMEOUT_MS = 'soon';
    expect(() => loadRedisConfig(env({}))).toThrow(/must be an integer/);

    process.env.REDIS_COMMAND_TIMEOUT_MS = '999999';
    expect(() => loadRedisConfig(env({}))).toThrow(/must be between/);
  });

  it('rejects an unparseable boolean rather than silently treating it as false', () => {
    process.env.REDIS_REQUIRED = 'maybe';
    expect(() => loadRedisConfig(env({}))).toThrow(/must be a boolean/);
  });
});

describe('redactUrl', () => {
  it('masks the password but keeps the host readable', () => {
    const out = redactUrl('redis://:sup3rs3cret@redis.internal:6379');
    expect(out).not.toContain('sup3rs3cret');
    expect(out).toContain('redis.internal');
  });

  it('masks a username too', () => {
    expect(redactUrl('rediss://admin:pw@host:6380')).not.toContain('admin');
  });

  it('reveals nothing beyond the scheme for an unparseable value', () => {
    expect(redactUrl('redis://::::garbage')).toBe('redis://***');
  });

  it('reports an unset URL plainly', () => {
    expect(redactUrl(null)).toBe('(unset)');
  });
});
