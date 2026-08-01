import { Injectable, LogLevel, LoggerService, Optional } from '@nestjs/common';
import { RequestContextStore } from '../request-context/request-context';
import { redactObject, redactText } from './redact';

/**
 * The one log writer for the whole process.
 *
 * HOW IT REPLACES "AD-HOC LOGGING" WITHOUT TOUCHING ANY CALL SITE
 * --------------------------------------------------------------
 * Roughly thirty services already do `private readonly logger = new
 * Logger(Something.name)` and call `this.logger.log(...)`. Nest's `Logger` is a
 * facade: it forwards to whatever instance is installed with
 * `app.useLogger(...)`. Installing this class therefore restructures every one
 * of those existing lines — adding a timestamp, a level, a request ID and a
 * user ID, and putting them through redaction — with no edit to any of them.
 *
 * Rewriting those call sites by hand would have been a large, risky diff that
 * touched business logic to change observability. This is the same outcome
 * with a one-line change in main.ts.
 *
 * TWO FORMATS, ONE SOURCE
 * -----------------------
 *   json    one object per line, for production. Greppable by requestId and
 *           parseable by any log platform without a custom pattern.
 *   pretty  aligned and coloured, for a terminal.
 *
 * The requirement "logs should remain human-readable" is met in both: the JSON
 * is one line with `message` in it, so `grep <requestId> | jq -r .message`
 * reads like a plain log, and a human scanning raw output can still follow it.
 * The default follows NODE_ENV; LOG_FORMAT overrides.
 *
 * WHY IT WRITES TO STDOUT DIRECTLY
 * --------------------------------
 * Every deployment target here — Docker's json-file driver, Render's log
 * drain — collects stdout. Writing to a file would mean log rotation,
 * permissions and a read-only container filesystem to argue with. `console` is
 * used rather than a raw stream write so that Node's own stdout handling
 * (including the synchronous-on-a-pipe behaviour that keeps ordering intact)
 * applies.
 */

/** Ascending severity. Anything below the configured floor is discarded. */
const LEVEL_WEIGHT: Record<LogLevel, number> = {
  verbose: 10,
  debug: 20,
  log: 30,
  warn: 40,
  error: 50,
  fatal: 60,
};

const LEVEL_LABEL: Record<LogLevel, string> = {
  verbose: 'VERBOSE',
  debug: 'DEBUG',
  log: 'INFO',
  warn: 'WARN',
  error: 'ERROR',
  fatal: 'FATAL',
};

const ANSI: Record<LogLevel, string> = {
  verbose: '\x1b[90m',
  debug: '\x1b[36m',
  log: '\x1b[32m',
  warn: '\x1b[33m',
  error: '\x1b[31m',
  fatal: '\x1b[35m',
};
const ANSI_RESET = '\x1b[0m';
const ANSI_DIM = '\x1b[90m';

/** Envelope keys a caller's structured field must never overwrite. */
const RESERVED_FIELDS = new Set([
  'timestamp',
  'level',
  'context',
  'message',
  'requestId',
  'userId',
  'actor',
  'stack',
]);

/** Structured fields a caller can attach to one line. */
export interface LogFields {
  [key: string]: unknown;
}

export interface StructuredLoggerOptions {
  format?: 'json' | 'pretty';
  minLevel?: LogLevel;
  /** Injected in tests to capture output instead of writing to stdout. */
  sink?: (line: string, level: LogLevel) => void;
}

@Injectable()
export class StructuredLogger implements LoggerService {
  private readonly format: 'json' | 'pretty';
  private readonly minWeight: number;
  private readonly sink: (line: string, level: LogLevel) => void;

  // `@Optional()` is REQUIRED, not decorative. With emitDecoratorMetadata on,
  // Nest reads this parameter's design-time type (`Object`) and tries to
  // resolve a provider for it — a TypeScript default value is invisible to the
  // container, so DI fails at boot with "can't resolve dependencies of
  // StructuredLogger". Marked optional, Nest passes undefined and the default
  // applies. The parameter exists so tests can construct a logger with a
  // capturing sink.
  constructor(@Optional() options: StructuredLoggerOptions = {}) {
    this.format = options.format ?? resolveFormat();
    this.minWeight = LEVEL_WEIGHT[options.minLevel ?? resolveMinLevel()];
    this.sink = options.sink ?? defaultSink;
  }

  // ── Nest LoggerService surface ─────────────────────────────────────────────
  // Nest calls these with a trailing context string, and `error` with an
  // optional stack before it. parseParams below untangles that.

  log(message: unknown, ...params: unknown[]): void {
    this.emit('log', message, params);
  }

  warn(message: unknown, ...params: unknown[]): void {
    this.emit('warn', message, params);
  }

  error(message: unknown, ...params: unknown[]): void {
    this.emit('error', message, params);
  }

  debug(message: unknown, ...params: unknown[]): void {
    this.emit('debug', message, params);
  }

  verbose(message: unknown, ...params: unknown[]): void {
    this.emit('verbose', message, params);
  }

  fatal(message: unknown, ...params: unknown[]): void {
    this.emit('fatal', message, params);
  }

  // ── Structured surface ─────────────────────────────────────────────────────

  /**
   * Emit a line with explicit structured fields.
   *
   * Used by the access log, which has real fields (status, latency, ip) rather
   * than a sentence. Fields are redacted; the request context is merged in
   * automatically, exactly as it is for the facade methods above.
   */
  write(level: LogLevel, context: string, message: string, fields?: LogFields): void {
    if (LEVEL_WEIGHT[level] < this.minWeight) return;
    // Fields go through redaction exactly like the message. The access log
    // carries request-derived values (user agent, and whatever a future caller
    // adds), so "the caller will remember to sanitise" is not a guarantee this
    // layer can rely on — the guarantee has to live here.
    this.output(
      level,
      context,
      redactText(message),
      undefined,
      fields ? (redactObject(fields) as LogFields) : undefined,
    );
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  private emit(level: LogLevel, message: unknown, params: unknown[]): void {
    if (LEVEL_WEIGHT[level] < this.minWeight) return;

    const { context, stack, extras } = parseParams(level, params);
    const { text, fields } = normalizeMessage(message);

    this.output(
      level,
      context,
      text,
      stack,
      extras.length > 0 ? { ...fields, details: redactObject(extras) } : fields,
    );
  }

  private output(
    level: LogLevel,
    context: string | undefined,
    message: string,
    stack: string | undefined,
    fields: LogFields | undefined,
  ): void {
    const request = RequestContextStore.get();

    const record: Record<string, unknown> = {
      timestamp: new Date().toISOString(),
      level: LEVEL_LABEL[level],
      context: context ?? 'Application',
      message,
    };

    // Correlation first — these are the fields anyone actually searches on, so
    // they sit near the front of the JSON object where they are easy to spot
    // when reading raw output.
    if (request) {
      record.requestId = request.requestId;
      if (request.userId) record.userId = request.userId;
      if (request.actor && request.actor !== 'anonymous') record.actor = request.actor;
    }

    // Merge caller fields, but never let one shadow an envelope field. A field
    // literally named `level` or `timestamp` would otherwise produce a record
    // whose meaning depends on JSON key ordering — and silently break every
    // downstream filter built on those fields.
    if (fields) {
      for (const [key, value] of Object.entries(fields)) {
        if (value === undefined) continue;
        record[RESERVED_FIELDS.has(key) ? `field_${key}` : key] = value;
      }
    }
    if (stack) record.stack = stack;

    this.sink(
      this.format === 'json' ? safeStringify(record) : this.pretty(level, record),
      level,
    );
  }

  private pretty(level: LogLevel, record: Record<string, unknown>): string {
    const colour = process.stdout.isTTY ? ANSI[level] : '';
    const reset = process.stdout.isTTY ? ANSI_RESET : '';
    const dim = process.stdout.isTTY ? ANSI_DIM : '';

    const time = String(record.timestamp).slice(11, 23); // HH:MM:SS.mmm
    const label = LEVEL_LABEL[level].padEnd(5);
    const requestId = record.requestId ? ` ${dim}(${String(record.requestId).slice(0, 8)})${reset}` : '';

    // Everything that is not part of the fixed prefix is appended as key=value
    // so structured fields stay visible in a terminal instead of being lost.
    const known = new Set(['timestamp', 'level', 'context', 'message', 'requestId', 'stack']);
    const rest = Object.entries(record)
      .filter(([key, value]) => !known.has(key) && value !== undefined)
      .map(([key, value]) => `${key}=${formatScalar(value)}`)
      .join(' ');

    const head =
      `${dim}${time}${reset} ${colour}${label}${reset} ` +
      `${dim}[${String(record.context)}]${reset}${requestId} ${String(record.message)}`;

    const tail = rest ? ` ${dim}${rest}${reset}` : '';
    const stack = record.stack ? `\n${dim}${String(record.stack)}${reset}` : '';
    return head + tail + stack;
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function resolveFormat(): 'json' | 'pretty' {
  const explicit = process.env.LOG_FORMAT?.trim().toLowerCase();
  if (explicit === 'json' || explicit === 'pretty') return explicit;
  return process.env.NODE_ENV === 'production' ? 'json' : 'pretty';
}

function resolveMinLevel(): LogLevel {
  const explicit = process.env.LOG_LEVEL?.trim().toLowerCase();
  if (explicit && explicit in LEVEL_WEIGHT) return explicit as LogLevel;
  // `log` and above by default: debug/verbose are opt-in, so a production
  // deployment does not pay to ship them and the signal stays readable.
  return 'log';
}

function defaultSink(line: string, level: LogLevel): void {
  // stderr for problems, stdout for everything else — the split every log
  // collector and every `2>` redirect already understands.
  if (level === 'error' || level === 'fatal') process.stderr.write(`${line}\n`);
  else process.stdout.write(`${line}\n`);
}

/**
 * Untangle Nest's trailing arguments.
 *
 * `logger.log(msg)` on a `new Logger('Ctx')` arrives as `(msg, 'Ctx')`, while
 * `logger.error(msg, stack)` arrives as `(msg, stack, 'Ctx')`. There is no
 * flag distinguishing them, so they are told apart by shape: a context is a
 * short single-line string, a stack is long or multi-line.
 */
function parseParams(
  level: LogLevel,
  params: unknown[],
): { context?: string; stack?: string; extras: unknown[] } {
  const rest = [...params];
  let context: string | undefined;
  let stack: string | undefined;

  const last = rest[rest.length - 1];
  if (typeof last === 'string' && !last.includes('\n') && last.length <= 80) {
    context = rest.pop() as string;
  }

  if (level === 'error' || level === 'fatal') {
    const index = rest.findIndex((p) => typeof p === 'string' && looksLikeStack(p));
    if (index !== -1) stack = rest.splice(index, 1)[0] as string;
  }

  return { context, stack, extras: rest };
}

function looksLikeStack(value: string): boolean {
  return value.includes('\n') || /\s+at\s+\S+/.test(value);
}

/** Accept a string, an Error, or an arbitrary object as the message. */
function normalizeMessage(message: unknown): { text: string; fields?: LogFields } {
  if (typeof message === 'string') return { text: redactText(message) };

  if (message instanceof Error) {
    return { text: redactText(message.message), fields: { errorName: message.name } };
  }

  if (message && typeof message === 'object') {
    const redacted = redactObject(message) as Record<string, unknown>;
    // Objects logged as a message keep a readable summary AND their fields, so
    // neither the terminal view nor the searchable view loses information.
    const text = typeof redacted.message === 'string' ? redacted.message : safeStringify(redacted);
    return { text, fields: { payload: redacted } };
  }

  return { text: String(message) };
}

/**
 * JSON.stringify that cannot throw.
 *
 * A log call is the last place that should raise: a circular reference in a
 * payload someone logged for debugging must not become a 500. Circular refs
 * are replaced, and total failure degrades to a marker rather than an
 * exception.
 */
function safeStringify(value: unknown): string {
  const seen = new WeakSet<object>();
  try {
    return JSON.stringify(value, (_key, val: unknown) => {
      if (typeof val === 'object' && val !== null) {
        if (seen.has(val)) return '[circular]';
        seen.add(val);
      }
      return val;
    });
  } catch {
    return '"[unserialisable log payload]"';
  }
}

function formatScalar(value: unknown): string {
  if (typeof value === 'string') return value.includes(' ') ? `"${value}"` : value;
  if (typeof value === 'object') return safeStringify(value);
  return String(value);
}
