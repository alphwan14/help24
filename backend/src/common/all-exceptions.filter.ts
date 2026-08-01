import {
  ExceptionFilter,
  Catch,
  ArgumentsHost,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { Request, Response } from 'express';
import {
  REQUEST_ID_HEADER,
  RequestContextStore,
} from './request-context/request-context';

/**
 * The last stop for every error.
 *
 * WHAT CHANGED IN THE INFRASTRUCTURE PHASE
 * ----------------------------------------
 *   • The response body now carries `requestId`. That single field turns a
 *     support conversation from "it failed sometime this morning" into one
 *     log query, which is the entire point of request correlation — an ID that
 *     only exists server-side helps nobody holding a phone.
 *   • Extra fields on an HttpException body are preserved instead of being
 *     flattened to `message`. The rate limiter needs `retryAfterSeconds` and
 *     `policy` to reach the client; previously they would have been discarded.
 *   • Stack traces are logged for every unhandled error, and the log line
 *     carries the request ID because StructuredLogger reads it from the
 *     AsyncLocalStorage context this filter still runs inside.
 *
 * The response shape is otherwise byte-compatible: `statusCode`, `message`,
 * `path` and `timestamp` keep their names, positions and meanings, so no
 * existing client parsing breaks.
 *
 * WHY THE FILTER STILL SEES THE REQUEST CONTEXT
 * ---------------------------------------------
 * RequestContextMiddleware calls `next()` inside `AsyncLocalStorage.run(...)`.
 * Everything downstream — including the rejected promise that lands here —
 * runs in that async scope, so `RequestContextStore.get()` resolves without
 * this filter being given anything. It is constructed with `new` in main.ts
 * and has no dependencies to inject, which is exactly why the store is static.
 */
@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger(AllExceptionsFilter.name);

  catch(exception: unknown, host: ArgumentsHost): void {
    const ctx = host.switchToHttp();
    const response = ctx.getResponse<Response>();
    const request = ctx.getRequest<Request>();

    let status = HttpStatus.INTERNAL_SERVER_ERROR;
    let message: string | string[] = 'Internal server error';
    // Fields an exception chose to expose beyond the standard envelope.
    let extra: Record<string, unknown> = {};

    if (exception instanceof HttpException) {
      status = exception.getStatus();
      const body = exception.getResponse();
      if (typeof body === 'string') {
        message = body;
      } else if (typeof body === 'object' && body !== null) {
        const { message: bodyMessage, statusCode, error, ...rest } = body as Record<string, unknown>;
        if (typeof bodyMessage === 'string' || Array.isArray(bodyMessage)) {
          message = bodyMessage as string | string[];
        }
        // `statusCode` and `error` are dropped from `rest` because they are
        // re-emitted below from the authoritative values; anything else the
        // thrower attached is passed through.
        extra = rest;
      }
    } else if (exception instanceof Error) {
      message = exception.message;
      this.logger.error(`Unhandled: ${exception.message}`, exception.stack);
    } else {
      // A thrown non-Error (a string, an object). Rare, but it must not
      // produce an empty log line — this is the case that is hardest to
      // diagnose precisely because nothing carries a stack.
      this.logger.error(`Unhandled non-Error throw: ${safeDescribe(exception)}`);
    }

    if (status >= 500) {
      this.logger.error(`${request.method} ${request.url} → ${status}`);
    }

    const requestId = RequestContextStore.requestId();

    // Belt and braces. The middleware already set this header, but an error
    // raised before it ran (or a response that replaced its headers) would
    // otherwise answer without one — and the ID is most valuable on exactly
    // the responses that went wrong.
    if (requestId && !response.headersSent) {
      response.setHeader(REQUEST_ID_HEADER, requestId);
    }

    response.status(status).json({
      statusCode: status,
      message: Array.isArray(message) ? message.join('; ') : message,
      path: request.url,
      timestamp: new Date().toISOString(),
      ...(requestId ? { requestId } : {}),
      ...extra,
    });
  }
}

function safeDescribe(value: unknown): string {
  try {
    return typeof value === 'object' ? JSON.stringify(value) : String(value);
  } catch {
    return Object.prototype.toString.call(value);
  }
}
