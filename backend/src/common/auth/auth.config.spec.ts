import { loadAuthConfig, shouldEnforce, AuthConfig } from './auth.config';

function load(env: Record<string, string | undefined>): AuthConfig {
  return loadAuthConfig(env as NodeJS.ProcessEnv);
}

describe('loadAuthConfig', () => {
  it('defaults to monitor when AUTH_ENFORCEMENT is unset', () => {
    // The only value that is both non-breaking for a shipped client AND
    // self-reporting. `enforce` would 401 the fleet on a deploy that forgot the
    // variable; `off` would run with no posture and no way to tell.
    expect(load({}).mode).toBe('monitor');
    expect(load({ AUTH_ENFORCEMENT: '' }).mode).toBe('monitor');
    expect(load({ AUTH_ENFORCEMENT: '   ' }).mode).toBe('monitor');
  });

  it('accepts the three modes, case-insensitively', () => {
    expect(load({ AUTH_ENFORCEMENT: 'off' }).mode).toBe('off');
    expect(load({ AUTH_ENFORCEMENT: 'MONITOR' }).mode).toBe('monitor');
    expect(load({ AUTH_ENFORCEMENT: ' Enforce ' }).mode).toBe('enforce');
  });

  it('fails the boot on an unrecognised mode rather than guessing', () => {
    expect(() => load({ AUTH_ENFORCEMENT: 'on' })).toThrow(/Invalid AUTH_ENFORCEMENT/);
    expect(() => load({ AUTH_ENFORCEMENT: 'true' })).toThrow(/Invalid AUTH_ENFORCEMENT/);
  });

  it('refuses an allowlist that cannot take effect', () => {
    // AUTH_ENFORCE_ONLY without enforce mode reads as though those routes were
    // protected. Silently ignoring it is how a team believes payments are
    // enforced when nothing is.
    expect(() => load({ AUTH_ENFORCE_ONLY: '/mpesa' })).toThrow(/only has meaning in enforce mode/);
    expect(() => load({ AUTH_ENFORCEMENT: 'monitor', AUTH_ENFORCE_ONLY: '/mpesa' })).toThrow(
      /only has meaning in enforce mode/,
    );
    expect(() =>
      load({ AUTH_ENFORCEMENT: 'enforce', AUTH_ENFORCE_ONLY: '/mpesa' }),
    ).not.toThrow();
  });

  it('caps the cache TTL so an entry can never outlive a token', () => {
    const config = load({ AUTH_TOKEN_CACHE_TTL_MS: String(24 * 60 * 60 * 1000) });
    expect(config.cacheMaxTtlMs).toBeLessThanOrEqual(15 * 60 * 1000);
  });

  it('rejects nonsensical numeric settings', () => {
    expect(() => load({ AUTH_TOKEN_CACHE_MAX: '0' })).toThrow(/positive integer/);
    expect(() => load({ AUTH_TOKEN_CACHE_MAX: '-5' })).toThrow(/positive integer/);
    expect(() => load({ AUTH_TOKEN_CACHE_MAX: 'lots' })).toThrow(/positive integer/);
  });

  it('caches by default and can be switched off explicitly', () => {
    expect(load({}).cacheEnabled).toBe(true);
    expect(load({ AUTH_TOKEN_CACHE: 'false' }).cacheEnabled).toBe(false);
  });
});

describe('shouldEnforce', () => {
  const base = load({ AUTH_ENFORCEMENT: 'enforce' });

  it('is false in off and monitor regardless of route', () => {
    expect(shouldEnforce(load({ AUTH_ENFORCEMENT: 'off' }), 'POST', '/jobs/approve')).toBe(false);
    expect(shouldEnforce(load({ AUTH_ENFORCEMENT: 'monitor' }), 'POST', '/jobs/approve')).toBe(false);
  });

  it('is true everywhere in enforce with no allowlist', () => {
    expect(shouldEnforce(base, 'POST', '/jobs/approve')).toBe(true);
    expect(shouldEnforce(base, 'GET', '/feed')).toBe(true);
  });

  it('narrows to a path prefix', () => {
    const config = load({ AUTH_ENFORCEMENT: 'enforce', AUTH_ENFORCE_ONLY: '/mpesa,/jobs' });
    expect(shouldEnforce(config, 'POST', '/mpesa/initiate')).toBe(true);
    expect(shouldEnforce(config, 'POST', '/jobs/approve')).toBe(true);
    expect(shouldEnforce(config, 'GET', '/feed')).toBe(false);
  });

  it('narrows to a method-qualified route', () => {
    const config = load({
      AUTH_ENFORCEMENT: 'enforce',
      AUTH_ENFORCE_ONLY: 'POST /jobs/approve',
    });
    expect(shouldEnforce(config, 'POST', '/jobs/approve')).toBe(true);
    expect(shouldEnforce(config, 'GET', '/jobs/approve')).toBe(false);
    expect(shouldEnforce(config, 'POST', '/jobs/mark-complete')).toBe(false);
  });
});
