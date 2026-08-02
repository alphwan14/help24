import { Injectable, Logger } from '@nestjs/common';
import { createHash } from 'node:crypto';
import { getAuth } from 'firebase-admin/auth';
import { FirebaseAdminService } from '../../notifications/firebase-admin.service';
import { AuthConfig, loadAuthConfig } from './auth.config';
import { AuthFailureReason, AuthenticatedIdentity, VerificationResult } from './auth.types';

/**
 * THE ONE PLACE A FIREBASE ID TOKEN IS VERIFIED.
 *
 * WHY A SERVICE AND NOT A FUNCTION IN THE MIDDLEWARE
 * -------------------------------------------------
 * The requirement is "verify once per request, never twice". The way that
 * requirement is usually broken is not by someone calling verify twice in one
 * function — it is by a second component growing its own need for identity and
 * doing its own verification, because the first one's result was not reachable
 * from where the second one runs. Concentrating verification behind one
 * injectable, with the result attached to the request object, means the answer
 * to "I need the caller's identity here" is always `req.auth` and never
 * `verifyIdToken`. There is exactly one call site of `verifyIdToken` in this
 * codebase and a test asserts it stays that way.
 *
 * WHAT VERIFICATION ACTUALLY COSTS
 * --------------------------------
 * `verifyIdToken` checks an RS256 signature against Google's published signing
 * keys, which firebase-admin fetches once and caches in-process for their
 * Cache-Control lifetime (~6 hours). So the steady state is a local RSA
 * verification — tens to a few hundred microseconds — with NO network round
 * trip. The exceptions are the first request after boot and the moment Google
 * rotates keys, which cost one shared HTTPS fetch amortised across every
 * concurrent request.
 *
 * `checkRevoked` is deliberately NOT enabled. It forces a network call to
 * Firebase on EVERY request, which would make this API's latency and
 * availability a function of Firebase's, and would defeat the caching below
 * entirely. The trade is explicit: a revoked session stays usable until the
 * token expires (at most an hour). For a marketplace where the destructive
 * actions all require an ownership match against a resource, that window is an
 * acceptable exposure; for a bank it would not be.
 */
@Injectable()
export class TokenVerifierService {
  private readonly logger = new Logger(TokenVerifierService.name);
  private readonly config: AuthConfig;

  /**
   * Verified tokens, keyed by digest.
   *
   * WHY THIS IS SAFE. A cache hit returns an identity that a signature check
   * already proved, for a token that has not yet expired. It cannot admit a
   * forged token — a forgery never got into the cache, because it never
   * verified. The only property it changes is how quickly this process notices
   * a REVOKED token, and since revocation is not checked at all (above), the
   * cache extends no window that was not already open. Entry lifetime is capped
   * at both the configured ceiling and the token's own `exp`, so an entry can
   * never outlive the credential it represents.
   *
   * WHY IT IS WORTH HAVING. This client polls: payment status every 5s while an
   * STK prompt is outstanding, job status every 30s, telemetry every 8s. One
   * signed-in device holds one token for an hour and will present it hundreds
   * of times. Caching turns that into one verification.
   *
   * A plain Map is the right structure: insertion order gives LRU eviction for
   * free, and at the configured ceiling the memory is bounded and small
   * (10k entries × ~200 bytes ≈ 2 MB).
   */
  private readonly cache = new Map<string, CacheEntry>();

  private readonly stats = {
    verified: 0,
    cacheHits: 0,
    cacheEvictions: 0,
    failures: 0,
    byReason: new Map<AuthFailureReason, number>(),
  };

  /** Verification failures are common and uninteresting; log a sample. */
  private lastFailureLogAt = 0;
  private static readonly FAILURE_LOG_INTERVAL_MS = 60_000;

  constructor(private readonly firebase: FirebaseAdminService) {
    this.config = loadAuthConfig();
  }

  /**
   * Verify a raw bearer token.
   *
   * NEVER THROWS. Every outcome — including "Firebase is down" — comes back as
   * a value, because the caller (middleware, on the request path) must be able
   * to decide what an unverifiable token means without a try/catch, and because
   * an exception here would convert Firebase's availability into this API's.
   */
  async verify(token: string): Promise<VerificationResult> {
    const trimmed = token.trim();
    if (!trimmed) return this.fail('malformed', 'empty token');

    // A Firebase ID token is a three-part JWS. Rejecting anything else before
    // touching the crypto costs one string scan and keeps the obvious garbage
    // — an admin token sent to the wrong route, a truncated header — out of the
    // verification path and out of the failure logs.
    if (trimmed.split('.').length !== 3) {
      return this.fail('malformed', 'not a JWT');
    }

    const key = this.config.cacheEnabled ? digest(trimmed) : null;
    if (key) {
      const hit = this.readCache(key);
      if (hit) {
        this.stats.cacheHits++;
        return { outcome: 'verified', identity: hit, cached: true };
      }
    }

    const app = this.firebase.app;
    if (!app) {
      // Unconfigured is an OPERATOR error, not a caller error, and it must
      // never be reported as a bad credential. Under enforcement this becomes a
      // 503 and the boot banner has already said why.
      return this.fail('unavailable', 'Firebase Admin is not configured');
    }

    try {
      const decoded = await getAuth(app).verifyIdToken(trimmed);
      const identity: AuthenticatedIdentity = {
        uid: decoded.uid,
        email: decoded.email,
        phoneNumber: decoded.phone_number,
        expiresAt: decoded.exp,
        authTime: decoded.auth_time,
      };

      this.stats.verified++;
      if (key) this.writeCache(key, identity);
      return { outcome: 'verified', identity, cached: false };
    } catch (err) {
      const reason = classify(err);
      this.logFailure(reason, err);
      return this.fail(reason, err instanceof Error ? err.message : String(err));
    }
  }

  /** Counters for the health surface and the boot banner. */
  snapshot(): Readonly<{
    verified: number;
    cacheHits: number;
    cacheSize: number;
    cacheEvictions: number;
    failures: number;
    byReason: Record<string, number>;
    hitRate: number;
  }> {
    const lookups = this.stats.verified + this.stats.cacheHits;
    return {
      verified: this.stats.verified,
      cacheHits: this.stats.cacheHits,
      cacheSize: this.cache.size,
      cacheEvictions: this.stats.cacheEvictions,
      failures: this.stats.failures,
      byReason: Object.fromEntries(this.stats.byReason),
      hitRate: lookups === 0 ? 0 : Math.round((this.stats.cacheHits / lookups) * 1000) / 1000,
    };
  }

  /** Drop every cached identity. Used by tests and available for an incident. */
  clearCache(): void {
    this.cache.clear();
  }

  private readCache(key: string): AuthenticatedIdentity | null {
    const entry = this.cache.get(key);
    if (!entry) return null;

    // Two independent expiries are checked, not one: the entry's own TTL, and
    // the token's `exp`. The second is what guarantees a cached identity can
    // never outlive its credential even if the TTL ceiling is misconfigured
    // upward or the process clock moves.
    const now = Date.now();
    if (entry.expiresAtMs <= now || entry.identity.expiresAt * 1000 <= now) {
      this.cache.delete(key);
      return null;
    }

    // Refresh recency so the hot set survives eviction.
    this.cache.delete(key);
    this.cache.set(key, entry);
    return entry.identity;
  }

  private writeCache(key: string, identity: AuthenticatedIdentity): void {
    const now = Date.now();
    const tokenRemainingMs = identity.expiresAt * 1000 - now;
    // An already-expired or near-expired token is not worth an entry; caching
    // it would only add an eviction.
    if (tokenRemainingMs <= 1000) return;

    const ttl = Math.min(this.config.cacheMaxTtlMs, tokenRemainingMs);
    this.cache.set(key, { identity, expiresAtMs: now + ttl });

    while (this.cache.size > this.config.cacheMaxEntries) {
      const oldest = this.cache.keys().next();
      if (oldest.done) break;
      this.cache.delete(oldest.value);
      this.stats.cacheEvictions++;
    }
  }

  private fail(reason: AuthFailureReason, detail?: string): VerificationResult {
    this.stats.failures++;
    this.stats.byReason.set(reason, (this.stats.byReason.get(reason) ?? 0) + 1);
    return { outcome: 'failed', reason, detail };
  }

  private logFailure(reason: AuthFailureReason, err: unknown): void {
    // `unavailable` is an operational fault and is always worth a line —
    // sampling it would hide an outage. Caller-side failures are sampled.
    const isOperational = reason === 'unavailable';
    const now = Date.now();
    if (!isOperational && now - this.lastFailureLogAt < TokenVerifierService.FAILURE_LOG_INTERVAL_MS) {
      return;
    }
    if (!isOperational) this.lastFailureLogAt = now;

    const message = `[AUTH] token verification failed (${reason}): ${
      err instanceof Error ? err.message : String(err)
    }`;

    if (isOperational) this.logger.error(message);
    else this.logger.debug(`${message} (further caller-side failures suppressed for 60s)`);
  }
}

interface CacheEntry {
  readonly identity: AuthenticatedIdentity;
  readonly expiresAtMs: number;
}

/**
 * Cache key. SHA-256 rather than the token itself so that a heap dump, a
 * debugger session or an accidental log of the cache cannot yield a working
 * credential. The digest is not reversible into a token.
 */
function digest(token: string): string {
  return createHash('sha256').update(token).digest('base64url');
}

/**
 * Map a firebase-admin error onto the reason the CLIENT needs.
 *
 * The consequential split is `unavailable` versus everything else. If Google's
 * key endpoint is unreachable, `verifyIdToken` throws — and a naive classifier
 * calls that an invalid token, answers 401, and every signed-in user is told
 * their session is bad and asked to log in again, simultaneously, over an
 * outage they cannot fix. Detecting it and answering 503 instead keeps clients
 * retrying rather than signing out.
 */
function classify(err: unknown): AuthFailureReason {
  const code = String((err as { code?: unknown })?.code ?? '').toLowerCase();
  const message = (err instanceof Error ? err.message : String(err)).toLowerCase();

  if (code.includes('id-token-expired') || message.includes('token has expired')) return 'expired';
  if (code.includes('id-token-revoked') || message.includes('has been revoked')) return 'revoked';
  if (code.includes('user-disabled')) return 'revoked';

  // Key retrieval and transport faults. These are OUR problem, never the
  // caller's, and the message is the only reliable signal firebase-admin gives.
  if (
    message.includes('error fetching public keys') ||
    message.includes('failed to fetch') ||
    code.includes('network') ||
    code.includes('unavailable') ||
    ['ENOTFOUND', 'ECONNREFUSED', 'ETIMEDOUT', 'ECONNRESET', 'EAI_AGAIN'].some((c) =>
      message.toUpperCase().includes(c),
    )
  ) {
    return 'unavailable';
  }

  if (code.includes('argument-error') || message.includes('decoding')) return 'malformed';
  return 'invalid';
}
