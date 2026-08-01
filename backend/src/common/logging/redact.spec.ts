import { redactObject, redactText } from './redact';

/**
 * Redaction is the only structural guarantee that a secret does not reach a
 * log file, so these tests are written as ASSERTIONS ABOUT LEAKS, not about
 * formatting: each one names a specific value that must never appear in
 * output, and fails if it does.
 */
describe('redactText', () => {
  it('masks a bearer token while keeping the scheme visible', () => {
    const out = redactText('Authorization: Bearer sk_live_abcdef1234567890');
    expect(out).not.toContain('sk_live_abcdef1234567890');
    expect(out).toContain('Bearer');
  });

  it('masks a JWT anywhere in the line', () => {
    const jwt =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk';
    const out = redactText(`session restore failed for token ${jwt}`);
    expect(out).not.toContain(jwt);
    expect(out).toContain('[REDACTED_JWT]');
  });

  it('masks sensitive fields inside an already-serialised JSON string', () => {
    // This is the shape the M-Pesa callback handlers actually log:
    // `JSON.stringify(body)`. The object is gone by the time it reaches a
    // logger, so key-based redaction cannot help and text matching must.
    const out = redactText('[STK] callback: {"password":"hunter2","otp_code":"483920","amount":100}');
    expect(out).not.toContain('hunter2');
    expect(out).not.toContain('483920');
    expect(out).toContain('"amount":100');
  });

  it('masks the middle of Kenyan phone numbers in both formats', () => {
    expect(redactText('payer 254712345678 paid')).toBe('payer 254******678 paid');
    expect(redactText('payer 0712345678 paid')).toBe('payer 071****678 paid');
  });

  it('leaves a UUID intact even when its last segment is all digits', () => {
    // Without the lookarounds in the MSISDN patterns, a 12-digit UUID segment
    // starting with 254 would be mangled — quietly making IDs untraceable in
    // exactly the logs someone is reading to trace something.
    const uuid = 'a1b2c3d4-e5f6-7890-abcd-254123456789';
    expect(redactText(`post ${uuid} archived`)).toContain(uuid);
  });

  it('honours LOG_MASK_PII=false for local payment debugging', () => {
    const previous = process.env.LOG_MASK_PII;
    process.env.LOG_MASK_PII = 'false';
    try {
      expect(redactText('payer 254712345678')).toContain('254712345678');
      // Credentials are NOT covered by the PII switch — they are always masked.
      expect(redactText('Bearer abcdef1234567890')).not.toContain('abcdef1234567890');
    } finally {
      if (previous === undefined) delete process.env.LOG_MASK_PII;
      else process.env.LOG_MASK_PII = previous;
    }
  });

  it('is a no-op on ordinary text', () => {
    const message = '[FEED] ranked 42 posts in 18ms';
    expect(redactText(message)).toBe(message);
  });
});

describe('redactObject', () => {
  it('masks by key name, case- and separator-insensitively', () => {
    const out = redactObject({
      MPESA_CONSUMER_SECRET: 'live-secret',
      consumerSecret: 'live-secret',
      'private-key': 'live-secret',
      accessToken: 'live-secret',
      postId: 'p-1',
    }) as Record<string, unknown>;

    expect(JSON.stringify(out)).not.toContain('live-secret');
    expect(out.postId).toBe('p-1');
  });

  it('recurses into nested objects and arrays', () => {
    const out = redactObject({
      user: { name: 'Ada', password: 'hunter2' },
      attempts: [{ token: 'abc' }, { token: 'def' }],
    });
    expect(JSON.stringify(out)).not.toContain('hunter2');
    expect(JSON.stringify(out)).not.toContain('abc');
  });

  it('does not mutate or return the original object', () => {
    const original = { password: 'hunter2', keep: 1 };
    const out = redactObject(original) as Record<string, unknown>;
    expect(original.password).toBe('hunter2');
    expect(out).not.toBe(original);
  });

  it('survives a circular reference without hanging', () => {
    // A log call must never be the thing that takes the process down.
    const node: Record<string, unknown> = { name: 'a' };
    node.self = node;
    expect(() => redactObject(node)).not.toThrow();
  });

  it('truncates very long arrays instead of serialising everything', () => {
    const out = redactObject(Array.from({ length: 200 }, (_, i) => i)) as unknown[];
    expect(out.length).toBeLessThanOrEqual(51);
    expect(String(out[out.length - 1])).toContain('truncated');
  });

  it('converts an Error into a loggable record with its stack', () => {
    const out = redactObject(new Error('boom')) as Record<string, unknown>;
    expect(out.message).toBe('boom');
    expect(typeof out.stack).toBe('string');
  });
});
