import { Request, Response } from 'express';
import {
  REQUEST_ID_HEADER,
  RequestContext,
  RequestContextStore,
  sanitizeInboundRequestId,
} from './request-context';
import { RequestContextMiddleware } from './request-context.middleware';

describe('sanitizeInboundRequestId', () => {
  it('accepts a well-formed client-supplied id', () => {
    expect(sanitizeInboundRequestId('mobile-7f3a91c2-0004')).toBe('mobile-7f3a91c2-0004');
  });

  it('rejects an id containing a newline', () => {
    // The log-injection case: an accepted newline would let a caller forge
    // entries in the log stream by embedding them in their own request id.
    expect(sanitizeInboundRequestId('abc123\nFAKE ENTRY level=ERROR')).toBeNull();
  });

  it('rejects an id containing CRLF', () => {
    // The header-injection case: CR/LF echoed into a response header splits
    // the response.
    expect(sanitizeInboundRequestId('abc12345\r\nX-Admin: true')).toBeNull();
  });

  it('rejects ids that are too short or too long to be useful', () => {
    expect(sanitizeInboundRequestId('abc')).toBeNull();
    expect(sanitizeInboundRequestId('a'.repeat(200))).toBeNull();
  });

  it('rejects non-strings', () => {
    expect(sanitizeInboundRequestId(undefined)).toBeNull();
    expect(sanitizeInboundRequestId(['a'.repeat(20)])).toBeNull();
  });
});

describe('RequestContextStore', () => {
  const base: RequestContext = {
    requestId: 'req-1',
    inherited: false,
    method: 'GET',
    path: '/feed',
    ip: '10.0.0.1',
    startedAt: 0,
  };

  it('returns undefined outside a request', () => {
    expect(RequestContextStore.get()).toBeUndefined();
    expect(RequestContextStore.requestId()).toBeUndefined();
  });

  it('makes the context visible to synchronous callees', () => {
    RequestContextStore.run({ ...base }, () => {
      expect(RequestContextStore.requestId()).toBe('req-1');
    });
  });

  it('survives await boundaries and timers', async () => {
    // This is the property the whole design depends on: a service called three
    // layers down, after several awaits, still sees the same request id
    // without anyone having passed it.
    await RequestContextStore.run({ ...base }, async () => {
      await Promise.resolve();
      await new Promise((resolve) => setTimeout(resolve, 5));
      expect(RequestContextStore.requestId()).toBe('req-1');
    });
  });

  it('keeps concurrent requests isolated', async () => {
    // Two overlapping requests must never see each other's ids — the failure
    // this prevents is a log line attributed to the wrong user.
    const one = RequestContextStore.run({ ...base, requestId: 'a' }, async () => {
      await new Promise((resolve) => setTimeout(resolve, 10));
      return RequestContextStore.requestId();
    });
    const two = RequestContextStore.run({ ...base, requestId: 'b' }, async () => {
      await new Promise((resolve) => setTimeout(resolve, 1));
      return RequestContextStore.requestId();
    });

    expect(await Promise.all([one, two])).toEqual(['a', 'b']);
  });

  it('annotate() updates the live context and is a no-op outside one', () => {
    expect(() => RequestContextStore.annotate({ userId: 'u1' })).not.toThrow();

    RequestContextStore.run({ ...base }, () => {
      RequestContextStore.annotate({ userId: 'u1', userIdSource: 'verified' });
      expect(RequestContextStore.get()?.userId).toBe('u1');
      expect(RequestContextStore.get()?.userIdSource).toBe('verified');
    });
  });
});

describe('RequestContextMiddleware', () => {
  const middleware = new RequestContextMiddleware();

  function fakeRequest(overrides: Partial<Request> = {}): Request {
    return {
      method: 'POST',
      originalUrl: '/mpesa/initiate?user_id=u-1',
      url: '/mpesa/initiate?user_id=u-1',
      ip: '196.201.1.1',
      headers: { 'user-agent': 'Dart/3.5 (dart:io)' },
      socket: {},
      ...overrides,
    } as unknown as Request;
  }

  function fakeResponse(): Response & { headers: Record<string, string> } {
    const headers: Record<string, string> = {};
    return {
      headers,
      setHeader: (name: string, value: string) => {
        headers[name] = value;
      },
    } as unknown as Response & { headers: Record<string, string> };
  }

  it('generates an id, echoes it, and exposes it downstream', () => {
    const res = fakeResponse();
    let seen: string | undefined;

    middleware.use(fakeRequest(), res, () => {
      seen = RequestContextStore.requestId();
    });

    expect(seen).toBeDefined();
    expect(res.headers[REQUEST_ID_HEADER]).toBe(seen);
  });

  it('sets the response header BEFORE calling next', () => {
    // If the header were set after next(), a handler that threw would produce
    // a response with no id — losing correlation on exactly the requests that
    // most need it.
    const res = fakeResponse();
    let headerAtNext: string | undefined;

    middleware.use(fakeRequest(), res, () => {
      headerAtNext = res.headers[REQUEST_ID_HEADER];
    });

    expect(headerAtNext).toBeDefined();
  });

  it('adopts a valid inbound id and marks it inherited', () => {
    const req = fakeRequest({
      headers: { 'x-request-id': 'device-abc12345' } as Request['headers'],
    });
    let context: RequestContext | undefined;

    middleware.use(req, fakeResponse(), () => {
      context = RequestContextStore.get();
    });

    expect(context?.requestId).toBe('device-abc12345');
    expect(context?.inherited).toBe(true);
  });

  it('replaces a hostile inbound id rather than rejecting the request', () => {
    const req = fakeRequest({
      headers: { 'x-request-id': 'evil\r\nX-Injected: 1' } as Request['headers'],
    });
    let context: RequestContext | undefined;

    middleware.use(req, fakeResponse(), () => {
      context = RequestContextStore.get();
    });

    expect(context?.requestId).not.toContain('\r');
    expect(context?.inherited).toBe(false);
  });

  it('strips the query string from the recorded path', () => {
    // The query carries user_id and coordinates on this API; repeating it on
    // every log line for the request would spread PII across the whole log.
    let context: RequestContext | undefined;
    middleware.use(fakeRequest(), fakeResponse(), () => {
      context = RequestContextStore.get();
    });

    expect(context?.path).toBe('/mpesa/initiate');
  });
});
