import { Logger } from '@nestjs/common';
import { RequestContextStore } from '../request-context/request-context';
import { StructuredLogger } from './structured-logger.service';

function capture(options: { format?: 'json' | 'pretty'; minLevel?: 'debug' | 'log' | 'warn' } = {}) {
  const lines: string[] = [];
  const logger = new StructuredLogger({
    format: options.format ?? 'json',
    minLevel: options.minLevel ?? 'log',
    sink: (line) => lines.push(line),
  });
  return { logger, lines, parsed: () => lines.map((l) => JSON.parse(l) as Record<string, unknown>) };
}

const CONTEXT = {
  requestId: 'req-abc-123',
  inherited: false,
  method: 'POST',
  path: '/mpesa/initiate',
  ip: '196.201.1.1',
  startedAt: 0,
};

describe('StructuredLogger — required fields', () => {
  it('emits timestamp, level, context and message', () => {
    const { logger, parsed } = capture();
    logger.log('ranked 42 posts', 'FeedService');

    const [record] = parsed();
    expect(record.level).toBe('INFO');
    expect(record.context).toBe('FeedService');
    expect(record.message).toBe('ranked 42 posts');
    expect(typeof record.timestamp).toBe('string');
    expect(new Date(record.timestamp as string).toString()).not.toBe('Invalid Date');
  });

  it('attaches the request id automatically, with no call-site change', () => {
    // The property the whole design rests on: an existing `this.logger.log()`
    // in any of the thirty-odd services gains correlation for free.
    const { logger, parsed } = capture();
    RequestContextStore.run(CONTEXT, () => logger.log('anything', 'SomeService'));
    expect(parsed()[0].requestId).toBe('req-abc-123');
  });

  it('attaches the user id when one has been resolved', () => {
    const { logger, parsed } = capture();
    RequestContextStore.run({ ...CONTEXT }, () => {
      RequestContextStore.annotate({ userId: 'user-9', actor: 'user' });
      logger.log('did a thing', 'JobsService');
    });
    expect(parsed()[0].userId).toBe('user-9');
    expect(parsed()[0].actor).toBe('user');
  });

  it('omits correlation fields outside a request rather than inventing them', () => {
    const { logger, parsed } = capture();
    logger.log('background sweep tick', 'PromotionsSweepService');
    expect(parsed()[0].requestId).toBeUndefined();
  });
});

describe('StructuredLogger — Nest argument shapes', () => {
  it('separates a stack trace from the context on error()', () => {
    // Nest calls `error(message, stack, context)`; there is no flag telling
    // them apart, so they are distinguished by shape.
    const { logger, parsed } = capture();
    const stack = 'Error: boom\n    at Object.<anonymous> (/app/src/x.ts:1:1)';
    logger.error('Unhandled: boom', stack, 'AllExceptionsFilter');

    const [record] = parsed();
    expect(record.context).toBe('AllExceptionsFilter');
    expect(record.stack).toBe(stack);
    expect(record.message).toBe('Unhandled: boom');
  });

  it('handles error() with only a context', () => {
    const { logger, parsed } = capture();
    logger.error('something failed', 'MpesaService');
    expect(parsed()[0].context).toBe('MpesaService');
    expect(parsed()[0].stack).toBeUndefined();
  });

  it('accepts an Error object as the message', () => {
    const { logger, parsed } = capture();
    logger.error(new Error('kaboom'), 'X');
    expect(parsed()[0].message).toBe('kaboom');
  });

  it('accepts an object as the message and keeps it queryable', () => {
    const { logger, parsed } = capture();
    logger.log({ event: 'payout', amount: 500 }, 'MpesaService');
    expect(parsed()[0].payload).toMatchObject({ event: 'payout', amount: 500 });
  });
});

describe('StructuredLogger — redaction', () => {
  it('scrubs credentials from a plain string message', () => {
    const { logger, lines } = capture();
    logger.log('restoring session with Bearer sk_live_9f8a7b6c5d4e3f2a', 'AdminAuthService');
    expect(lines[0]).not.toContain('sk_live_9f8a7b6c5d4e3f2a');
  });

  it('scrubs a serialised callback payload — the real M-Pesa logging shape', () => {
    const { logger, lines } = capture();
    logger.log(
      `[STK] callback received: ${JSON.stringify({
        PhoneNumber: '254712345678',
        password: 'hunter2',
      })}`,
      'MpesaService',
    );
    expect(lines[0]).not.toContain('hunter2');
    expect(lines[0]).not.toContain('254712345678');
  });

  it('scrubs structured fields passed through write()', () => {
    const { logger, lines } = capture();
    logger.write('log', 'HTTP', 'POST /admin/session/restore 200', {
      authorization: 'Bearer abcdef123456',
      status: 200,
    });
    expect(lines[0]).not.toContain('abcdef123456');
    expect(lines[0]).toContain('"status":200');
  });
});

describe('StructuredLogger — levels and format', () => {
  it('drops messages below the configured floor', () => {
    const { logger, lines } = capture({ minLevel: 'warn' });
    logger.log('chatty');
    logger.debug('chattier');
    logger.warn('important');
    expect(lines).toHaveLength(1);
  });

  it('emits one line per record in json mode', () => {
    const { logger, lines } = capture();
    logger.log('a');
    logger.log('b');
    expect(lines).toHaveLength(2);
    expect(lines[0].includes('\n')).toBe(false);
  });

  it('renders a readable single line in pretty mode, including structured fields', () => {
    const lines: string[] = [];
    const logger = new StructuredLogger({ format: 'pretty', sink: (l) => lines.push(l) });
    RequestContextStore.run(CONTEXT, () =>
      logger.write('log', 'HTTP', 'POST /mpesa/initiate 201', { status: 201, latencyMs: 42 }),
    );

    expect(lines[0]).toContain('POST /mpesa/initiate 201');
    expect(lines[0]).toContain('[HTTP]');
    expect(lines[0]).toContain('status=201');
    expect(lines[0]).toContain('latencyMs=42');
  });

  it('never throws on a circular payload', () => {
    const { logger } = capture();
    const node: Record<string, unknown> = { a: 1 };
    node.self = node;
    expect(() => logger.log(node, 'X')).not.toThrow();
  });
});

describe('StructuredLogger — installed as Nest global logger', () => {
  it('reformats existing `new Logger(X)` call sites without touching them', () => {
    // This is the migration claim, tested end to end: an untouched service
    // logging the way it always has now produces a structured, correlated
    // record.
    const { logger, parsed } = capture();
    Logger.overrideLogger(logger);
    try {
      const serviceLogger = new Logger('MpesaService');
      RequestContextStore.run(CONTEXT, () => serviceLogger.log('[STK] initiate — post=p1'));

      const [record] = parsed();
      expect(record.context).toBe('MpesaService');
      expect(record.requestId).toBe('req-abc-123');
      expect(record.message).toBe('[STK] initiate — post=p1');
    } finally {
      Logger.overrideLogger(false);
    }
  });
});
