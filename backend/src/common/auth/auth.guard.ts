import {
  CanActivate,
  ExecutionContext,
  ForbiddenException,
  Inject,
  Injectable,
  Logger,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { Request } from 'express';
import { RequestContextStore } from '../request-context/request-context';
import { AUTH_SPEC_KEY, AuthSpec } from './auth.decorator';
import { AuthConfig, shouldEnforce } from './auth.config';
import { AUTH_CONFIG } from './auth.tokens';
import {
  applyBindings,
  conflictsIn,
  describeOutcomes,
  resolveConflictsToVerified,
} from './identity-binding';
import { AUTH_ERROR_CODES, AuthErrorCode, AuthFailureReason, RequestWithIdentity } from './auth.types';

/**
 * Enforces the authentication scheme each route declares.
 *
 * WHAT THIS GUARD DOES NOT DO: VERIFY TOKENS.
 * -------------------------------------------
 * Verification happened once already, in IdentityMiddleware, and the result is
 * on `req.auth`. That split is the answer to "verify once per request": the
 * middleware RESOLVES identity, this guard ENFORCES policy. Putting
 * verification in the guard instead would break two things — the rate limiter
 * (a guard, and it runs first, so it would key on an identity that did not
 * exist yet) and the access log for rejected requests (identity would be
 * unknown for exactly the requests worth investigating).
 *
 * REGISTERED GLOBALLY AND FAILING CLOSED
 * --------------------------------------
 * A route that declares no scheme is treated as PROTECTED, not as public. This
 * inverts the failure mode the same way the rate limiter's global registration
 * does: forgetting a decorator makes an endpoint stricter than intended, which
 * shows up immediately as a 401 in testing, rather than looser than intended,
 * which shows up as a breach. The boot-time route audit lists every undeclared
 * route so the omission is fixed rather than tolerated.
 *
 * ORDER
 * -----
 * RateLimitGuard runs BEFORE this one (AuthModule is imported after
 * RateLimitModule in AppModule — that ordering is load-bearing and commented
 * there). Cheap rejection first: a flood of unauthenticated requests is
 * absorbed by the limiter without ever reaching identity handling. AdminAuthGuard
 * runs AFTER, as a controller-scoped guard, which is why the `admin` scheme
 * here is a stand-down rather than a check.
 */
@Injectable()
export class AuthGuard implements CanActivate {
  private readonly logger = new Logger(AuthGuard.name);

  /** Undeclared-route warnings are per route, once each — not per request. */
  private readonly warnedRoutes = new Set<string>();

  /**
   * Last time a WOULD_DENY line was emitted for a given route.
   *
   * Sampled, because in `monitor` mode the unauthenticated case is not an
   * anomaly — it is EVERY request from every shipped client. An unsampled warn
   * would double this API's log volume at exactly the moment the migration
   * wants logs to be readable, and would cost real money on a hosted platform.
   * The complete, countable signal lives in the access log's `authWouldDeny`
   * field, which is emitted once per request either way; this line exists so a
   * human tailing the logs can see the migration working.
   */
  private readonly lastWouldDenyLogAt = new Map<string, number>();
  private static readonly WOULD_DENY_LOG_INTERVAL_MS = 60_000;

  constructor(
    private readonly reflector: Reflector,
    @Inject(AUTH_CONFIG) private readonly config: AuthConfig,
  ) {}

  canActivate(context: ExecutionContext): boolean {
    // Background sweeps and lifecycle hooks are not requests and have no
    // caller. They reach the database through the service-role key by design.
    if (context.getType() !== 'http') return true;

    const req = context.switchToHttp().getRequest<Request & RequestWithIdentity>();
    const spec = this.reflector.getAllAndOverride<AuthSpec | undefined>(AUTH_SPEC_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);

    // A critical route is enforced no matter what the migration env says —
    // `critical: true` in the spec outranks AUTH_ENFORCEMENT/AUTH_ENFORCE_ONLY.
    // See @AuthCritical: routes that decide where money goes must not be one
    // env edit away from monitor behaviour.
    const enforcing =
      spec?.critical === true || shouldEnforce(this.config, req.method, req.path);

    if (!spec) return this.handleUndeclared(req, context, enforcing);

    RequestContextStore.annotate({ authScheme: spec.scheme, authEnforced: enforcing });

    switch (spec.scheme) {
      case 'admin':
        // AdminAuthGuard owns this route. Annotating the actor here keeps the
        // access log honest about which credential system was in play.
        RequestContextStore.annotate({ actor: 'admin' });
        return true;

      case 'public':
        return this.handlePublic(req, spec, enforcing);

      case 'firebase':
        return this.handleProtected(req, spec, enforcing);
    }
  }

  /**
   * A public route. Never rejected — but a personalisation claim from an
   * anonymous caller is not honoured under enforcement (see identity-binding).
   */
  private handlePublic(
    req: Request & RequestWithIdentity,
    spec: AuthSpec,
    enforcing: boolean,
  ): boolean {
    if (spec.bindings.length === 0) return true;

    const uid = req.auth?.uid ?? null;
    const outcomes = applyBindings(req, uid, spec.bindings, { enforcing });

    if (uid) {
      // On a public route a mismatch is not an attack on authorization — the
      // route would have served an anonymous caller anyway. It is a request to
      // personalise as someone else, and the verified identity simply wins.
      resolveConflictsToVerified(req, uid, outcomes);
    }

    const conflicts = conflictsIn(outcomes);
    if (conflicts.length > 0) {
      this.logger.warn(
        `[AUTH][PERSONALISATION_OVERRIDE] ${req.method} ${req.path} — ` +
          `${describeOutcomes(outcomes)} uid=${uid ?? 'anonymous'}`,
      );
    }
    return true;
  }

  /** A route that requires a Firebase identity. */
  private handleProtected(
    req: Request & RequestWithIdentity,
    spec: AuthSpec,
    enforcing: boolean,
  ): boolean {
    const identity = req.auth;

    if (!identity) {
      const failure = req.authFailure?.reason ?? 'absent';

      if (!enforcing) {
        // The migration's readiness signal. Recorded on EVERY such request for
        // the access log (which is what a dashboard counts), and logged as a
        // warn at most once a minute per route so the stream stays readable.
        RequestContextStore.annotate({ authWouldDeny: failure });
        this.logWouldDeny(req, spec, failure);
        // Nothing is bound: there is no proven identity to bind. The request
        // proceeds on its asserted values exactly as it does today.
        return true;
      }

      throw this.reject(failure, req);
    }

    const outcomes = applyBindings(req, identity.uid, spec.bindings, { enforcing });
    const conflicts = conflictsIn(outcomes);

    if (conflicts.length === 0) return true;

    const summary =
      `${req.method} ${req.path} — uid=${identity.uid} ${describeOutcomes(outcomes)}`;

    if (!enforcing) {
      // Not merely observed — CORRECTED. The request continues, but as the
      // person the token proves rather than the person the body claimed. This
      // is what makes `monitor` a security improvement in its own right instead
      // of a purely diagnostic stage: a caller holding a valid token cannot act
      // as someone else even before enforcement is switched on.
      resolveConflictsToVerified(req, identity.uid, outcomes);
      this.logger.warn(`[AUTH][CONFLICT_CORRECTED] ${summary}`);
      RequestContextStore.annotate({ authWouldDeny: 'identity_conflict' });
      return true;
    }

    this.logger.warn(`[AUTH][CONFLICT_DENIED] ${summary}`);
    throw new ForbiddenException({
      statusCode: 403,
      error: 'Forbidden',
      code: AUTH_ERROR_CODES.IDENTITY_CONFLICT,
      message:
        'The identity in this request does not match the authenticated user.',
    });
  }

  /**
   * One sampled line per route, and none at all in `off`.
   *
   * `off` promises to be indistinguishable from the pre-auth system, and that
   * includes what it writes to the log — an operator who has deliberately
   * turned the migration off should not have their logs filled by it.
   */
  private logWouldDeny(req: Request, spec: AuthSpec, failure: AuthFailureReason): void {
    if (this.config.mode === 'off') return;

    const key = `${req.method} ${req.path}`;
    const now = Date.now();
    const last = this.lastWouldDenyLogAt.get(key) ?? 0;
    if (now - last < AuthGuard.WOULD_DENY_LOG_INTERVAL_MS) return;
    this.lastWouldDenyLogAt.set(key, now);

    this.logger.warn(
      `[AUTH][WOULD_DENY] ${key} — reason=${failure} mode=${this.config.mode} ` +
        `enforcing=false asserted=${describeAsserted(req, spec)} ` +
        `ua="${req.headers['user-agent'] ?? 'unknown'}" ` +
        `(further occurrences for this route suppressed for 60s; ` +
        `count them with authWouldDeny in the access log)`,
    );
  }

  /**
   * A route with no `@Auth`/`@Public`/`@AdminAuth` declaration.
   *
   * Under enforcement this is a 401: an endpoint nobody classified is an
   * endpoint nobody reasoned about, and serving it to an anonymous caller is
   * the worse of the two guesses. Before enforcement it is allowed, with a
   * one-time warning per route so it is fixed during the migration rather than
   * discovered at the moment enforcement is switched on.
   */
  private handleUndeclared(
    req: Request & RequestWithIdentity,
    context: ExecutionContext,
    enforcing: boolean,
  ): boolean {
    const label = `${context.getClass().name}.${context.getHandler().name}`;

    if (!this.warnedRoutes.has(label)) {
      this.warnedRoutes.add(label);
      this.logger.error(
        `[AUTH][UNDECLARED] ${req.method} ${req.path} (${label}) declares no auth ` +
          `scheme. Add @Auth(...), @Public('reason') or @AdminAuth(). ` +
          `Under AUTH_ENFORCEMENT=enforce this route answers 401.`,
      );
    }

    RequestContextStore.annotate({ authScheme: undefined, authEnforced: enforcing });

    if (!enforcing) return true;
    if (req.auth) return true; // A proven caller is admitted even here.

    throw this.reject(req.authFailure?.reason ?? 'absent', req);
  }

  /**
   * Turn a failure reason into the right status and the right machine code.
   *
   * `unavailable` becomes 503, never 401 — the caller's credentials were never
   * assessed, and telling a user their session is invalid because Firebase is
   * unreachable would sign out the entire user base over an outage none of them
   * caused. Everything else is a 401 carrying a code precise enough for the
   * client to choose between "refresh and retry" and "sign out".
   */
  private reject(reason: AuthFailureReason, req: Request): Error {
    if (reason === 'unavailable') {
      this.logger.error(
        `[AUTH][UNAVAILABLE] ${req.method} ${req.path} — identity could not be ` +
          `verified; answering 503 rather than 401 so clients retry instead of signing out.`,
      );
      return new ServiceUnavailableException({
        statusCode: 503,
        error: 'Service Unavailable',
        code: AUTH_ERROR_CODES.AUTH_UNAVAILABLE,
        message: 'Authentication is temporarily unavailable. Please try again shortly.',
      });
    }

    const code = CODE_BY_REASON[reason];
    return new UnauthorizedException({
      statusCode: 401,
      error: 'Unauthorized',
      code,
      message: MESSAGE_BY_CODE[code],
    });
  }
}

const CODE_BY_REASON: Record<Exclude<AuthFailureReason, 'unavailable'>, AuthErrorCode> = {
  absent: AUTH_ERROR_CODES.AUTH_REQUIRED,
  malformed: AUTH_ERROR_CODES.TOKEN_INVALID,
  expired: AUTH_ERROR_CODES.TOKEN_EXPIRED,
  revoked: AUTH_ERROR_CODES.TOKEN_REVOKED,
  invalid: AUTH_ERROR_CODES.TOKEN_INVALID,
};

const MESSAGE_BY_CODE: Record<AuthErrorCode, string> = {
  [AUTH_ERROR_CODES.AUTH_REQUIRED]: 'Sign in to continue.',
  [AUTH_ERROR_CODES.TOKEN_EXPIRED]: 'Your session has expired. Please try again.',
  [AUTH_ERROR_CODES.TOKEN_INVALID]: 'Your session is no longer valid. Please sign in again.',
  [AUTH_ERROR_CODES.TOKEN_REVOKED]: 'Your session was ended. Please sign in again.',
  [AUTH_ERROR_CODES.AUTH_UNAVAILABLE]:
    'Authentication is temporarily unavailable. Please try again shortly.',
  [AUTH_ERROR_CODES.IDENTITY_CONFLICT]:
    'The identity in this request does not match the authenticated user.',
};

/**
 * The identity the caller CLAIMED, for the would-deny log.
 *
 * Without it the log says a request would have been rejected but not who it
 * said it was — which is the field needed to tell "an old client that has not
 * updated" from "someone probing the API".
 */
function describeAsserted(req: Request, spec: AuthSpec): string {
  const parts: string[] = [];
  for (const binding of spec.bindings) {
    const bag = (binding.source === 'body' ? req.body : req.query) as
      | Record<string, unknown>
      | undefined;
    const value = bag?.[binding.field];
    if (typeof value === 'string' && value.trim() !== '') {
      parts.push(`${binding.source}.${binding.field}=${value.trim()}`);
    }
  }
  return parts.length > 0 ? parts.join(' ') : 'none';
}
