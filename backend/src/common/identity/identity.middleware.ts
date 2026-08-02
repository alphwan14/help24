import { Injectable, Logger, NestMiddleware } from '@nestjs/common';
import { NextFunction, Request, Response } from 'express';
import { RequestContextStore } from '../request-context/request-context';
import { TokenVerifierService } from '../auth/token-verifier.service';
import { AuthenticatedIdentity, RequestWithIdentity } from '../auth/auth.types';

/**
 * Resolves WHO is making a request — and never rejects one.
 *
 * THIS MIDDLEWARE STILL DOES NOT ENFORCE ANYTHING. THAT IS DELIBERATE.
 * --------------------------------------------------------------------
 * Its job is to answer "who is this?", attach the answer, and get out of the
 * way. Whether a given route REQUIRES that answer is a routing-level question,
 * and middleware runs before routing — it cannot see the `@Auth` decorator on
 * the handler it is about to run, so it could only ever enforce by matching
 * path strings. AuthGuard does the enforcing, after routing, with the handler
 * in hand. See auth.guard.ts.
 *
 * WHY THE SPLIT IS WORTH IT
 * -------------------------
 * Resolving here and enforcing later is what satisfies "verify once per
 * request" without starving anything of identity:
 *
 *   • RateLimitGuard runs before AuthGuard and keys its per-subject rules on
 *     `auth.uid`. Verification had to happen before ANY guard for those limits
 *     to be unspoofable.
 *   • The access log records identity for requests that were rejected — which
 *     are exactly the ones worth investigating. Had verification lived in the
 *     guard, a 401'd request would carry no identity at all.
 *   • Every downstream consumer reads `req.auth`. There is one call site of
 *     `verifyIdToken` in this codebase (in TokenVerifierService) and a test
 *     keeps it that way.
 *
 * WHY IT NEVER THROWS
 * -------------------
 * A verification failure here would convert Firebase's availability into this
 * API's availability for EVERY route, public ones included. Instead the failure
 * is recorded on the request as a reason, and the guard decides — per route —
 * whether that reason matters. A public route never learns there was a problem.
 */
@Injectable()
export class IdentityMiddleware implements NestMiddleware {
  private readonly logger = new Logger(IdentityMiddleware.name);

  constructor(private readonly verifier: TokenVerifierService) {}

  async use(req: Request & RequestWithIdentity, _res: Response, next: NextFunction): Promise<void> {
    try {
      await this.resolve(req);
    } catch (err) {
      // Belt and braces: `resolve` already swallows its own errors, and this
      // guarantees that no future edit to it can take a request down.
      this.logger.debug(
        `[IDENTITY] resolution failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
    // Marks that resolution ran to completion. Without it, "no token" and
    // "middleware never executed" look identical to the guard — and the second
    // is a misconfiguration that must not be mistaken for an anonymous caller.
    req.authResolved = true;
    next();
  }

  private async resolve(req: Request & RequestWithIdentity): Promise<void> {
    const token = readBearer(req);

    if (token === null) {
      // No credential presented. Recorded as a reason rather than left blank so
      // the guard's rejection path has one shape for every failure.
      req.authFailure = { reason: 'absent' };
      this.annotateAsserted(req);
      return;
    }

    const result = await this.verifier.verify(token);

    if (result.outcome === 'verified') {
      this.attach(req, result.identity);
      return;
    }

    req.authFailure = { reason: result.reason, detail: result.detail };
    this.annotateAsserted(req);
  }

  private attach(req: Request & RequestWithIdentity, identity: AuthenticatedIdentity): void {
    req.auth = identity;
    RequestContextStore.annotate({
      userId: identity.uid,
      userIdSource: 'verified',
      actor: 'user',
    });
  }

  /**
   * No proven identity. Record the ASSERTED one so logs stay useful for tracing
   * a session — clearly marked as unproven, because treating a body field as an
   * identity is precisely the weakness this labels.
   */
  private annotateAsserted(req: Request): void {
    const asserted = readAsserted(req);
    if (asserted) {
      RequestContextStore.annotate({ userId: asserted, userIdSource: 'asserted' });
    }
  }
}

/**
 * The bearer token, or null when none was presented.
 *
 * ADMIN ROUTES ARE SKIPPED. They carry an opaque Help24 admin token, not a
 * Firebase ID token, so attempting verification would fail on every admin
 * request — burning a signature check, polluting the failure counters that the
 * migration dashboard reads, and logging noise about a token that was never
 * meant for Firebase. AdminAuthGuard authenticates those routes; `@AdminAuth()`
 * declares it, and the boot-time route audit checks the two agree.
 */
function readBearer(req: Request): string | null {
  if (req.path.startsWith('/admin')) return null;

  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) return null;

  const token = header.slice(7).trim();
  return token === '' ? null : token;
}

/**
 * The identity the caller CLAIMS, in the field names this API actually uses.
 *
 * Ordered from most to least specific so that, on a request carrying both, the
 * one naming the acting party wins over a generic `user_id`.
 *
 * FOR LOGGING ONLY. Nothing authorizes on this value — the guard binds proven
 * identity onto the specific field each route declares, and that binding is
 * what the services read.
 */
function readAsserted(req: Request): string | undefined {
  const body = (req.body ?? {}) as Record<string, unknown>;
  const query = (req.query ?? {}) as Record<string, unknown>;

  const candidates = [
    body.user_id,
    body.buyer_user_id,
    body.client_user_id,
    body.provider_user_id,
    body.senderId,
    body.applicant_user_id,
    body.raised_by_user_id,
    body.client_id,
    query.user_id,
  ];

  for (const candidate of candidates) {
    if (typeof candidate === 'string' && candidate.trim() !== '') return candidate.trim();
  }
  return undefined;
}

/**
 * Re-exported so the many existing importers of these names keep compiling.
 * The definitions moved to `common/auth/auth.types.ts`, which is where the
 * whole auth vocabulary now lives.
 */
export type { AuthenticatedIdentity as VerifiedIdentity } from '../auth/auth.types';
export type RequestWithAuth = Request & RequestWithIdentity;
