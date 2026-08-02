import { AUTH_MODES, AuthMode } from './auth.types';

/**
 * Every authentication setting, parsed and validated in one place.
 *
 * Follows the convention configuration.ts documents: infrastructure settings
 * are parsed next to the code that depends on them, not in the central config,
 * and the parser runs during DI at boot so a malformed value aborts startup
 * rather than surfacing as strange behaviour hours later.
 */
export interface AuthConfig {
  readonly mode: AuthMode;
  /**
   * When non-empty, ONLY these route patterns are enforced; everything else
   * behaves as `monitor` regardless of `mode`.
   */
  readonly enforceOnly: readonly string[];
  readonly cacheEnabled: boolean;
  readonly cacheMaxEntries: number;
  readonly cacheMaxTtlMs: number;
}

const DEFAULT_CACHE_MAX_ENTRIES = 10_000;
const DEFAULT_CACHE_MAX_TTL_MS = 5 * 60 * 1000;

/**
 * The gap between a token being revoked and this process stopping accepting it.
 *
 * Verification is local (no revocation check — see token-verifier.service.ts),
 * so a revoked token is already accepted until it expires, cache or no cache.
 * The cache therefore does not create this exposure; it only must not EXTEND
 * it, which is why an entry's lifetime is capped at both this value and the
 * token's own remaining validity, whichever is shorter.
 */
const CACHE_TTL_CEILING_MS = 15 * 60 * 1000;

export function loadAuthConfig(env: NodeJS.ProcessEnv = process.env): AuthConfig {
  const mode = parseMode(env.AUTH_ENFORCEMENT);
  const enforceOnly = parseEnforceOnly(env.AUTH_ENFORCE_ONLY);

  if (enforceOnly.length > 0 && mode !== 'enforce') {
    throw new Error(
      `[Auth] AUTH_ENFORCE_ONLY is set but AUTH_ENFORCEMENT is "${mode}". ` +
        `The allowlist only has meaning in enforce mode — as written, it narrows ` +
        `nothing and reads as though those routes were protected when they are not. ` +
        `Set AUTH_ENFORCEMENT=enforce, or unset AUTH_ENFORCE_ONLY.`,
    );
  }

  return {
    mode,
    enforceOnly,
    cacheEnabled: env.AUTH_TOKEN_CACHE !== 'false',
    cacheMaxEntries: parsePositiveInt(
      env.AUTH_TOKEN_CACHE_MAX,
      DEFAULT_CACHE_MAX_ENTRIES,
      'AUTH_TOKEN_CACHE_MAX',
    ),
    cacheMaxTtlMs: Math.min(
      parsePositiveInt(env.AUTH_TOKEN_CACHE_TTL_MS, DEFAULT_CACHE_MAX_TTL_MS, 'AUTH_TOKEN_CACHE_TTL_MS'),
      CACHE_TTL_CEILING_MS,
    ),
  };
}

function parseMode(raw: string | undefined): AuthMode {
  const value = raw?.trim().toLowerCase();

  // Unset is the common case on an existing deployment and must not fail the
  // boot. `monitor` is the safe landing spot: identical behaviour to today,
  // and it starts producing the data needed to move on. main.ts states loudly
  // at boot that enforcement is not active, so this default cannot hide.
  if (!value) return 'monitor';

  if (!(AUTH_MODES as readonly string[]).includes(value)) {
    throw new Error(
      `[Auth] Invalid AUTH_ENFORCEMENT "${raw}". Expected one of: ${AUTH_MODES.join(', ')}.`,
    );
  }
  return value as AuthMode;
}

/**
 * Route patterns for graduated enforcement, e.g. `POST /mpesa/initiate` or a
 * prefix like `/jobs`.
 *
 * This exists because the risk is not evenly spread. Money endpoints are worth
 * enforcing the day the new client reaches most devices; the Discover feed can
 * wait for the long tail of upgrades. Without this the choice is all-or-nothing
 * and the temptation is to delay the whole thing for the least important route.
 */
function parseEnforceOnly(raw: string | undefined): readonly string[] {
  if (!raw?.trim()) return [];
  return raw
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => entry.toUpperCase());
}

/**
 * True when `mode` says enforce AND the allowlist (if any) admits this route.
 *
 * `method` and `path` are matched against entries that may be either a bare
 * path prefix (`/jobs`) or a method-qualified one (`POST /jobs/approve`).
 */
export function shouldEnforce(
  config: AuthConfig,
  method: string,
  path: string,
): boolean {
  if (config.mode !== 'enforce') return false;
  if (config.enforceOnly.length === 0) return true;

  const target = `${method.toUpperCase()} ${path}`;
  return config.enforceOnly.some((entry) => {
    if (entry.includes(' ')) return target.toUpperCase().startsWith(entry);
    return path.toUpperCase().startsWith(entry);
  });
}

function parsePositiveInt(raw: string | undefined, fallback: number, name: string): number {
  if (raw === undefined || raw.trim() === '') return fallback;
  const parsed = Number(raw);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error(`[Auth] ${name} must be a positive integer — got "${raw}".`);
  }
  return parsed;
}
