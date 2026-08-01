import { Injectable, LogLevel, NestMiddleware } from '@nestjs/common';
import { NextFunction, Request, Response } from 'express';
import { RequestContextStore } from '../request-context/request-context';
import { StructuredLogger } from './structured-logger.service';

/**
 * One structured line per HTTP request, emitted when the response completes.
 *
 * WHY `res.on('finish')` AND NOT AN INTERCEPTOR
 * ---------------------------------------------
 * An interceptor sees only requests that reach a handler. It never sees:
 *
 *   • 404s          — no route matched, so nothing was intercepted
 *   • 401 / 403     — a guard rejected the request before interceptors run
 *   • 429           — same: the rate-limit guard runs first
 *   • 400 from the  — the global ValidationPipe throws before the handler
 *     validation pipe
 *
 * That list is most of what an operator investigates. `finish` fires on the
 * response object for every one of them, plus the successes, so this is the
 * only placement that yields a genuinely complete access log.
 *
 * `close` is handled too: a client that disappears mid-response (a phone
 * leaving coverage, which this app's users do constantly) never fires
 * `finish`, and those requests would otherwise vanish from the log entirely —
 * exactly when someone is trying to work out why an action did not take.
 */
@Injectable()
export class AccessLogMiddleware implements NestMiddleware {
  constructor(private readonly logger: StructuredLogger) {}

  use(req: Request, res: Response, next: NextFunction): void {
    let settled = false;

    const complete = (aborted: boolean): void => {
      if (settled) return; // finish and close can both fire
      settled = true;
      this.emit(req, res, aborted);
    };

    res.on('finish', () => complete(false));
    res.on('close', () => complete(!res.writableEnded));

    next();
  }

  private emit(req: Request, res: Response, aborted: boolean): void {
    const context = RequestContextStore.get();

    const latencyMs = context
      ? Math.round((performance.now() - context.startedAt) * 100) / 100
      : undefined;

    const status = res.statusCode;

    this.logger.write(levelFor(status, req, aborted), 'HTTP', `${req.method} ${context?.path ?? req.path} ${status}`, {
      // ── The fields the brief asks for ──────────────────────────────────────
      // (timestamp, requestId and userId are added by StructuredLogger from
      // the request context — they are not repeated here.)
      method: req.method,
      endpoint: context?.path ?? req.path,
      status,
      latencyMs,
      ip: context?.ip ?? req.ip,
      userAgent: req.headers['user-agent'],

      // ── Fields earned by this system's specific failure modes ─────────────
      // The route PATTERN, not just the concrete path: `/jobs/:postId/status`
      // aggregates in a log platform, whereas `/jobs/<uuid>/status` produces a
      // distinct series per job and is useless for spotting a spike.
      route: routePattern(req),
      // Whether the caller's identity was proven or merely claimed. Without
      // this, `userId` in a log reads as authenticated when today it usually
      // is not — a distinction that matters when reconstructing an abuse case.
      userIdSource: context?.userIdSource,
      // The rate limiter's verdict, so a 429 investigation needs one query
      // rather than a join across two log streams.
      rateLimitPolicy: context?.rateLimitPolicy,
      rateLimited: context?.rateLimited || undefined,
      // A trace that began on the device keeps its ID; flagging it prevents an
      // operator from mistaking a client-chosen ID for a server-generated one.
      requestIdInherited: context?.inherited || undefined,
      aborted: aborted || undefined,
    });
  }
}

/**
 * Severity by outcome, with one deliberate exception.
 *
 *   5xx → error   the server failed
 *   4xx → warn    the caller failed; a burst is the signal for abuse or a
 *                 broken client release
 *   2xx → log
 *
 * The exception: a successful `GET /health`. The mobile app polls it as its
 * connectivity probe every ten seconds per device (see
 * ConnectivityProvider), so at any real user count it would be the
 * overwhelming majority of all log volume — drowning the signal and costing
 * money on a hosted log platform. Successful probes drop to `debug` (off by
 * default); a FAILING probe keeps its normal severity, because that is the
 * one an operator needs to see.
 */
function levelFor(status: number, req: Request, aborted: boolean): LogLevel {
  if (status >= 500) return 'error';
  if (status >= 400) return 'warn';
  if (aborted) return 'warn';
  if (req.method === 'GET' && (req.path === '/health' || req.path === '/')) return 'debug';
  return 'log';
}

/**
 * The Express route pattern for this request, e.g. `/jobs/:postId/status`.
 *
 * `req.route` is populated during dispatch, so it is available by the time the
 * response finishes. It is absent for 404s and for requests rejected before
 * routing, where the concrete path is all there is.
 */
function routePattern(req: Request): string | undefined {
  const route = (req as Request & { route?: { path?: string } }).route;
  if (!route?.path) return undefined;
  const base = req.baseUrl ?? '';
  const full = `${base}${route.path}`;
  return full === '' ? '/' : full;
}
