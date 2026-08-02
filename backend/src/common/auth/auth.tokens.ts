/**
 * DI token for the parsed AuthConfig.
 *
 * A symbol-like string token rather than a class, because AuthConfig is a plain
 * value object produced by `loadAuthConfig()` at module construction. Injecting
 * it — instead of having each consumer call `loadAuthConfig()` — means the
 * environment is read and validated exactly once per process, so the guard, the
 * verifier, the route audit and the boot banner cannot disagree about what mode
 * the system is running in.
 */
export const AUTH_CONFIG = 'help24:authConfig';
