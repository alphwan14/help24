import {
  CanActivate,
  ExecutionContext,
  HttpException,
  HttpStatus,
  Injectable,
  Logger,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { Request, Response } from 'express';
import { RequestContextStore } from '../request-context/request-context';
import { RATE_LIMIT_POLICY_KEY, RATE_LIMIT_SKIP_KEY } from './rate-limit.decorator';
import { RateLimitService } from './rate-limit.service';
import { RateLimitDecision } from './rate-limit.types';

/**
 * Applies the rate-limit catalogue to every HTTP request.
 *
 * REGISTERED GLOBALLY, ON PURPOSE
 * -------------------------------
 * A guard opted into per controller protects only what someone remembered to
 * opt in. Registered globally with a permissive default policy, the property
 * inverts: a new endpoint is protected the moment it exists, and the decorator
 * tightens rather than enables. The failure mode becomes "this limit is looser
 * than it should be" instead of "this endpoint has no limit" — the first is
 * visible in the catalogue, the second is invisible until it is exploited.
 *
 * WHY A GUARD AND NOT MIDDLEWARE
 * ------------------------------
 * Middleware runs before routing, so it cannot read the `@RateLimit`
 * decorator on the handler it is about to protect — it would be back to
 * matching path strings. A guard runs after routing with the handler in hand,
 * which is what makes decorator-bound policies possible. It also runs before
 * every controller-level guard (AdminAuthGuard included), so an invalid admin
 * token is rejected by the cheap check before it reaches a database lookup —
 * exactly the ordering that stops credential brute-forcing from becoming a
 * database load problem.
 */
@Injectable()
export class RateLimitGuard implements CanActivate {
  private readonly logger = new Logger(RateLimitGuard.name);

  constructor(
    private readonly reflector: Reflector,
    private readonly limiter: RateLimitService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    // Only HTTP. Background sweeps and lifecycle hooks are not requests and
    // have no caller to limit.
    if (context.getType() !== 'http') return true;

    const skip = this.reflector.getAllAndOverride<boolean>(RATE_LIMIT_SKIP_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (skip) return true;

    const policyName = this.reflector.getAllAndOverride<string | undefined>(
      RATE_LIMIT_POLICY_KEY,
      [context.getHandler(), context.getClass()],
    );

    const http = context.switchToHttp();
    const req = http.getRequest<RequestWithAuth>();
    const res = http.getResponse<Response>();

    const policy = this.limiter.resolvePolicy(policyName);

    const decision = await this.limiter.check(policy, {
      // `req.ip` respects `trust proxy`, which main.ts enables — without it
      // every caller behind Render's edge would share one identity and the IP
      // rules would throttle the entire user base collectively.
      ip: req.ip || req.socket?.remoteAddress || 'unknown',
      auth: req.auth as Record<string, unknown> | undefined,
      body: asRecord(req.body),
      query: asRecord(req.query),
      params: asRecord(req.params),
    });

    // Recorded on the request context so the access log carries the verdict —
    // one query answers "was this 429 ours, and under which policy?".
    RequestContextStore.annotate({
      rateLimitPolicy: policy.name,
      rateLimited: !decision.allowed,
    });

    this.applyHeaders(res, decision);

    if (decision.allowed) return true;

    const retryAfterSeconds = Math.max(1, Math.ceil((decision.limiting?.retryAfterMs ?? 1000) / 1000));

    this.logger.warn(
      `[RATELIMIT] DENIED ${req.method} ${req.path} — policy=${policy.name} ` +
        `rule=${decision.limiting?.ruleId ?? 'unknown'} retryAfter=${retryAfterSeconds}s` +
        `${decision.degraded ? ' (degraded: per-instance limits)' : ''}`,
    );

    // 429 with Retry-After is the standard contract, and the mobile client
    // already treats a non-2xx as a failure it can surface — no client change
    // is needed for this to behave correctly today.
    res.setHeader('Retry-After', String(retryAfterSeconds));
    throw new HttpException(
      {
        statusCode: HttpStatus.TOO_MANY_REQUESTS,
        message: 'Too many requests. Please slow down and try again shortly.',
        error: 'Too Many Requests',
        retryAfterSeconds,
        policy: policy.name,
      },
      HttpStatus.TOO_MANY_REQUESTS,
    );
  }

  /**
   * Standard rate-limit headers, in both spellings.
   *
   * `RateLimit-*` is the IETF draft form that newer tooling expects;
   * `X-RateLimit-*` is the de facto form that most existing HTTP clients and
   * dashboards already parse. Emitting both costs a few bytes and removes a
   * class of "the limit is invisible to my tooling" problem.
   *
   * Headers are set on ALLOWED responses too. That is what lets a
   * well-behaved client self-throttle before it is ever rejected, which is
   * strictly better for everyone than discovering the limit by hitting it.
   */
  private applyHeaders(res: Response, decision: RateLimitDecision): void {
    const limiting = decision.limiting;
    if (!limiting) return;

    const resetSeconds = Math.max(0, Math.ceil(limiting.retryAfterMs / 1000));

    res.setHeader('RateLimit-Limit', String(limiting.limit));
    res.setHeader('RateLimit-Remaining', String(limiting.remaining));
    res.setHeader('RateLimit-Reset', String(resetSeconds));
    res.setHeader('RateLimit-Policy', decision.policy);
    res.setHeader('X-RateLimit-Limit', String(limiting.limit));
    res.setHeader('X-RateLimit-Remaining', String(limiting.remaining));
    res.setHeader('X-RateLimit-Reset', String(resetSeconds));

    // Surfaced so a client — or a QA engineer following the checklist — can
    // tell "the limiter is running degraded" from "the limiter is fine", which
    // is otherwise only visible in server logs.
    if (decision.degraded) res.setHeader('RateLimit-Degraded', 'true');
  }
}

/** Express request plus the optional identity attached by IdentityMiddleware. */
interface RequestWithAuth extends Request {
  auth?: Record<string, unknown>;
}

/**
 * Narrow an unknown request member to a plain record.
 *
 * `req.body` is `any` and can be an array, a string (text bodies) or undefined
 * before a parser has run. Only a plain object can carry a named subject
 * field, so anything else resolves to no subject and the rule falls back to
 * the IP — never to an exception on the request path.
 */
function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined;
  return value as Record<string, unknown>;
}
