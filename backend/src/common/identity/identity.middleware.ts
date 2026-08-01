import { Injectable, Logger, NestMiddleware } from '@nestjs/common';
import { getAuth } from 'firebase-admin/auth';
import { NextFunction, Request, Response } from 'express';
import { FirebaseAdminService } from '../../notifications/firebase-admin.service';
import { RequestContextStore } from '../request-context/request-context';

/**
 * Resolves WHO is making a request — and never rejects one.
 *
 * READ THIS BEFORE ASSUMING IT AUTHENTICATES ANYTHING
 * ---------------------------------------------------
 * This middleware is deliberately NON-ENFORCING. It verifies a Firebase ID
 * token when one is present, attaches the result, and otherwise does nothing.
 * A request with a missing, expired or forged token proceeds exactly as it
 * does today.
 *
 * That is not an oversight, it is the scope boundary. This backend currently
 * takes identity from the request body (`buyer_user_id`, `user_id`,
 * `senderId`) on every user-facing route, and the mobile app does not send an
 * Authorization header to it at all — it sends one only to Supabase. Turning
 * on enforcement here would 401 every request from every shipped client. That
 * change belongs to an auth phase with a coordinated app release; this phase
 * builds the seam it will hang on.
 *
 * WHAT IT BUYS TODAY
 * ------------------
 *   1. The access log distinguishes a PROVEN identity from a CLAIMED one
 *      (`userIdSource: verified | asserted`). Without that distinction a
 *      `userId` in a log reads as authenticated when today it almost never is
 *      — which would mislead exactly the person reconstructing an abuse case.
 *   2. Rate-limit policies already list `auth.uid` first among their subject
 *      sources. The moment the app starts sending tokens, every per-subject
 *      limit becomes unspoofable with no further code change.
 *   3. It gives the auth phase one place to switch on, rather than thirty
 *      controllers to edit.
 *
 * WHY IT NEVER THROWS
 * -------------------
 * A verification failure here would convert Firebase's availability into this
 * API's availability. Since the result is advisory, an unverifiable token is
 * simply an absent identity.
 */
@Injectable()
export class IdentityMiddleware implements NestMiddleware {
  private readonly logger = new Logger(IdentityMiddleware.name);

  /** Verification failures are common and uninteresting; log a sample. */
  private lastFailureLogAt = 0;
  private static readonly FAILURE_LOG_INTERVAL_MS = 60_000;

  constructor(private readonly firebase: FirebaseAdminService) {}

  async use(req: RequestWithAuth, _res: Response, next: NextFunction): Promise<void> {
    try {
      await this.resolve(req);
    } catch (err) {
      // Belt and braces: `resolve` already swallows its own errors, and this
      // guarantees that no future edit to it can take a request down.
      this.logger.debug(
        `[IDENTITY] resolution failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
    next();
  }

  private async resolve(req: RequestWithAuth): Promise<void> {
    const verified = await this.verifyBearer(req);

    if (verified) {
      req.auth = verified;
      RequestContextStore.annotate({
        userId: verified.uid,
        userIdSource: 'verified',
        actor: 'user',
      });
      return;
    }

    // No proven identity. Record the ASSERTED one so logs are still useful for
    // tracing a user's session — clearly marked as unproven, because treating
    // a body field as an identity is precisely the weakness this labels.
    const asserted = readAsserted(req);
    if (asserted) {
      RequestContextStore.annotate({ userId: asserted, userIdSource: 'asserted' });
    }
  }

  private async verifyBearer(req: Request): Promise<VerifiedIdentity | null> {
    // Admin routes carry an opaque Help24 admin token, not a Firebase ID
    // token. Attempting verification on those would fail on every admin
    // request and log noise for a token that was never meant for Firebase.
    if (req.path.startsWith('/admin')) return null;

    const header = req.headers.authorization;
    if (!header?.startsWith('Bearer ')) return null;

    const token = header.slice(7).trim();
    if (!token) return null;

    const app = this.firebase.app;
    if (!app) return null; // Firebase not configured — nothing to verify against.

    try {
      // Local verification against Google's cached signing keys: no network
      // round trip in the common case, so this is microseconds, not
      // milliseconds. `checkRevoked` is deliberately NOT set — it would force
      // a network call per request for a signal this phase does not act on.
      const decoded = await getAuth(app).verifyIdToken(token);
      return {
        uid: decoded.uid,
        email: decoded.email,
        phoneNumber: decoded.phone_number,
      };
    } catch (err) {
      this.logFailure(err);
      return null;
    }
  }

  private logFailure(err: unknown): void {
    const now = Date.now();
    if (now - this.lastFailureLogAt < IdentityMiddleware.FAILURE_LOG_INTERVAL_MS) return;
    this.lastFailureLogAt = now;
    this.logger.debug(
      `[IDENTITY] Bearer token present but not verifiable: ` +
        `${err instanceof Error ? err.message : String(err)} ` +
        `(further occurrences suppressed for ${
          IdentityMiddleware.FAILURE_LOG_INTERVAL_MS / 1000
        }s)`,
    );
  }
}

export interface VerifiedIdentity {
  readonly uid: string;
  readonly email?: string;
  readonly phoneNumber?: string;
}

export interface RequestWithAuth extends Request {
  auth?: VerifiedIdentity;
}

/**
 * The identity the caller CLAIMS, in the field names this API actually uses.
 *
 * Ordered from most to least specific so that, on a request carrying both, the
 * one naming the acting party wins over a generic `user_id`.
 */
function readAsserted(req: Request): string | undefined {
  const body = (req.body ?? {}) as Record<string, unknown>;
  const query = (req.query ?? {}) as Record<string, unknown>;

  const candidates = [
    body.user_id,
    body.buyer_user_id,
    body.senderId,
    body.applicant_user_id,
    body.raised_by_user_id,
    query.user_id,
  ];

  for (const candidate of candidates) {
    if (typeof candidate === 'string' && candidate.trim() !== '') return candidate.trim();
  }
  return undefined;
}
