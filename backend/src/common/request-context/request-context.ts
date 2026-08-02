import { AsyncLocalStorage } from 'node:async_hooks';

/**
 * Per-request state that follows execution wherever it goes.
 *
 * WHY AsyncLocalStorage AND NOT A PARAMETER
 * -----------------------------------------
 * The requirement is that a request ID reaches every log line, every service
 * call, every interceptor and every exception filter. The alternative — a
 * context argument threaded through every method — would mean editing the
 * signature of essentially every function in this codebase, and would still
 * lose the ID the moment something forgot to pass it. AsyncLocalStorage
 * propagates through promises, timers and callbacks automatically, so the
 * thirty-odd services that already call `this.logger.log(...)` gain
 * correlation without a single line changing in any of them.
 *
 * That last point is the whole design: correlation had to be free at the call
 * site, or it would only ever be applied to the code someone remembered.
 *
 * WHAT IT COSTS
 * -------------
 * AsyncLocalStorage has a measurable but small overhead on async-heavy paths
 * (single-digit percent in Node 18+, where it is implemented on top of the
 * native async context). One store, entered once per request, is the cheapest
 * form of it. Reading is a pointer dereference.
 *
 * SCOPE BOUNDARY
 * --------------
 * The store is entered by RequestContextMiddleware and exists for the life of
 * the request. Code that runs outside a request — the three background sweeps,
 * bootstrap, shutdown — sees `undefined`, and every consumer must tolerate
 * that rather than assume a context exists.
 */
export interface RequestContext {
  /** Globally unique for this request. Echoed in the X-Request-Id header. */
  readonly requestId: string;
  /** True when the ID came from the client rather than being generated here. */
  readonly inherited: boolean;
  readonly method: string;
  /** Path only — the query string is NOT stored, since it can carry PII. */
  readonly path: string;
  readonly ip: string;
  readonly userAgent?: string;
  /** Monotonic start time (performance.now) for latency measurement. */
  readonly startedAt: number;

  /**
   * Mutable slots, filled in as the request is understood.
   *
   * These cannot be readonly: identity is resolved by middleware that runs
   * after the context is created, and the rate limiter annotates its own
   * outcome for the access log. Everything else about the context is fixed.
   */
  userId?: string;
  /** How `userId` was established — a trusted token, or merely asserted. */
  userIdSource?: 'verified' | 'asserted';
  actor?: 'user' | 'admin' | 'anonymous';
  /** Rate-limit policy applied, recorded for the access log. */
  rateLimitPolicy?: string;
  /** True when this request was rejected by the rate limiter. */
  rateLimited?: boolean;

  /**
   * The authentication scheme the ROUTE declared — `firebase`, `admin` or
   * `public`; undefined when the route declared none. Recorded separately from
   * `userIdSource`, which describes what the CALLER actually presented. The two
   * together are what makes the migration measurable: "firebase-scheme routes
   * where userIdSource is not verified" is precisely the set of requests that
   * enforcement will start rejecting.
   */
  authScheme?: 'firebase' | 'admin' | 'public';
  /** Whether enforcement was active for this route on this request. */
  authEnforced?: boolean;
  /**
   * Set when enforcement WOULD have rejected this request but the mode allowed
   * it through. Counting these by route is the readiness signal for flipping
   * AUTH_ENFORCEMENT to `enforce`; it must reach zero first.
   */
  authWouldDeny?: string;
}

/**
 * Request IDs are echoed into logs and response headers, so an unvalidated one
 * is a log-injection and header-injection vector: a client could send an ID
 * containing newlines and forge log entries, or CRLF and split the response.
 *
 * Accepting only this alphabet makes both impossible. Anything else is
 * discarded and a fresh ID is generated — the request still succeeds, it just
 * does not get to choose its own name.
 */
const SAFE_REQUEST_ID = /^[A-Za-z0-9._:-]{8,128}$/;

export function sanitizeInboundRequestId(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return SAFE_REQUEST_ID.test(trimmed) ? trimmed : null;
}

/**
 * Static, not injectable.
 *
 * The two consumers that matter most — the logger and the global exception
 * filter — are both constructed outside the DI container (the filter with
 * `new` in main.ts, the logger before the app is fully built). A static
 * accessor is reachable from anywhere, including plain functions, which is
 * what "attached to every log" actually requires.
 */
export class RequestContextStore {
  private static readonly storage = new AsyncLocalStorage<RequestContext>();

  /** Run `fn` with `context` visible to everything it awaits. */
  static run<T>(context: RequestContext, fn: () => T): T {
    return RequestContextStore.storage.run(context, fn);
  }

  /** The active context, or undefined outside a request. */
  static get(): RequestContext | undefined {
    return RequestContextStore.storage.getStore();
  }

  /** The active request ID, or undefined outside a request. */
  static requestId(): string | undefined {
    return RequestContextStore.storage.getStore()?.requestId;
  }

  /**
   * Update the mutable slots of the active context.
   *
   * A no-op outside a request, so callers never need to guard. Only the
   * fields declared mutable on RequestContext can be set.
   */
  static annotate(patch: Partial<Pick<RequestContext,
    'userId' | 'userIdSource' | 'actor' | 'rateLimitPolicy' | 'rateLimited'
    | 'authScheme' | 'authEnforced' | 'authWouldDeny'>>): void {
    const context = RequestContextStore.storage.getStore();
    if (!context) return;
    Object.assign(context, patch);
  }
}

/** Canonical header name — used for both the inbound read and the echo. */
export const REQUEST_ID_HEADER = 'X-Request-Id';
