import { Injectable, NestMiddleware } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { NextFunction, Request, Response } from 'express';
import {
  REQUEST_ID_HEADER,
  RequestContext,
  RequestContextStore,
  sanitizeInboundRequestId,
} from './request-context';

/**
 * Opens the request context. This must be the FIRST middleware in the chain.
 *
 * ORDERING — WHY MIDDLEWARE AND NOT AN INTERCEPTOR
 * ------------------------------------------------
 * Nest runs middleware before guards, pipes, interceptors and handlers, and
 * exception filters run inside the promise chain that middleware started. An
 * interceptor would be too late for two reasons that matter in production:
 *
 *   1. A request rejected by a guard (401, 403, 429) never reaches an
 *      interceptor — and those are precisely the requests someone is trying to
 *      debug.
 *   2. A request that matches no route (404) never reaches one either.
 *
 * Because `next()` is invoked inside `RequestContextStore.run(...)`, every
 * asynchronous continuation downstream — routing, guards, the handler, the
 * exception filter, and any fire-and-forget work the handler spawns —
 * inherits the same store. That is what "survives through service calls,
 * exception filters and interceptors" means mechanically.
 *
 * THE HEADER IS SET IMMEDIATELY, NOT AT THE END
 * ---------------------------------------------
 * `res.setHeader` is called before `next()`, so the ID is present on the
 * response whatever happens afterwards — including a 500 thrown from deep in a
 * service, which is the one case where the client most needs an ID to quote
 * in a bug report.
 */
@Injectable()
export class RequestContextMiddleware implements NestMiddleware {
  use(req: Request, res: Response, next: NextFunction): void {
    const context = buildContext(req);

    // Echo before anything can fail. Set on the raw response so it survives
    // whichever layer ends up writing the body.
    res.setHeader(REQUEST_ID_HEADER, context.requestId);

    RequestContextStore.run(context, () => next());
  }
}

function buildContext(req: Request): RequestContext {
  // A client-supplied ID is honoured so that a trace begun by the mobile app
  // (or by a future API gateway) stays a single trace end to end. It is
  // sanitised first — see sanitizeInboundRequestId for why that is not
  // optional — and it grants the caller nothing: the ID is a correlation
  // label, never an authorisation or identity signal.
  const inbound = sanitizeInboundRequestId(req.headers['x-request-id']);

  return {
    requestId: inbound ?? randomUUID(),
    inherited: inbound !== null,
    method: req.method,
    // Path only. `req.originalUrl` carries the query string, which on this API
    // includes user_id and coordinates — PII that has no business being
    // repeated on every log line for the request.
    path: stripQuery(req.originalUrl || req.url || '/'),
    ip: req.ip || req.socket?.remoteAddress || 'unknown',
    userAgent: req.headers['user-agent'],
    startedAt: performance.now(),
    actor: 'anonymous',
  };
}

function stripQuery(url: string): string {
  const index = url.indexOf('?');
  return index === -1 ? url : url.slice(0, index);
}
