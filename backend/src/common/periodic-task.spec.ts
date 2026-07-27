import { Logger } from '@nestjs/common';
import { PeriodicTask } from './periodic-task';

/**
 * These tests exist because the failure they guard against is invisible in
 * production: a sweep cut in half during a redeploy leaves a half-written
 * dispute escalation or a payout event marked attempted-but-undelivered, and
 * nothing logs an error because nothing threw — the process simply stopped.
 */

/** A logger that swallows output but lets us assert on what was said. */
function silentLogger(): Logger & { lines: string[] } {
  const lines: string[] = [];
  const logger = new Logger('test') as Logger & { lines: string[] };
  logger.lines = lines;
  jest.spyOn(logger, 'log').mockImplementation((m) => void lines.push(`log:${String(m)}`));
  jest.spyOn(logger, 'warn').mockImplementation((m) => void lines.push(`warn:${String(m)}`));
  jest.spyOn(logger, 'error').mockImplementation((m) => void lines.push(`error:${String(m)}`));
  return logger;
}

/**
 * Drain the microtask queue.
 *
 * A completed tick settles through `fn() → .catch() → .finally()`, so a single
 * `await Promise.resolve()` leaves `inFlight` still set and the next tick
 * correctly skipped — which looks exactly like a missed tick from the outside.
 * Flushing several times separates "the loop is broken" from "the promise
 * chain has not finished unwinding yet".
 */
async function flush(times = 5): Promise<void> {
  for (let i = 0; i < times; i++) await Promise.resolve();
}

/** A promise you resolve by hand, so a "slow tick" is deterministic. */
function deferred<T = void>() {
  let resolve!: (value: T) => void;
  let reject!: (err: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

describe('PeriodicTask', () => {
  let logger: Logger & { lines: string[] };

  beforeEach(() => {
    jest.useFakeTimers();
    logger = silentLogger();
  });

  afterEach(() => {
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  it('ticks on the interval', async () => {
    const task = new PeriodicTask('TEST', logger);
    const fn = jest.fn().mockResolvedValue(undefined);

    task.start(fn, 1000);
    expect(fn).not.toHaveBeenCalled(); // setInterval does not fire immediately

    jest.advanceTimersByTime(1000);
    expect(fn).toHaveBeenCalledTimes(1);

    await flush();
    jest.advanceTimersByTime(1000);
    expect(fn).toHaveBeenCalledTimes(2);

    await task.stop();
  });

  it('is idempotent on start — a double init must not double-tick', async () => {
    const task = new PeriodicTask('TEST', logger);
    const fn = jest.fn().mockResolvedValue(undefined);

    task.start(fn, 1000);
    task.start(fn, 1000);

    jest.advanceTimersByTime(1000);
    expect(fn).toHaveBeenCalledTimes(1);

    await task.stop();
  });

  // The bug only PromotionsSweepService had guarded against.
  it('skips a tick while the previous one is still running', async () => {
    const task = new PeriodicTask('TEST', logger);
    const slow = deferred();
    const fn = jest.fn().mockReturnValue(slow.promise);

    task.start(fn, 1000);

    jest.advanceTimersByTime(1000);
    expect(fn).toHaveBeenCalledTimes(1);

    // Three more intervals pass while the first tick is still in flight.
    jest.advanceTimersByTime(3000);
    expect(fn).toHaveBeenCalledTimes(1);

    slow.resolve();
    await flush();

    jest.advanceTimersByTime(1000);
    expect(fn).toHaveBeenCalledTimes(2);

    await task.stop();
  });

  it('skips, rather than queues, the ticks it missed', async () => {
    const task = new PeriodicTask('TEST', logger);
    const slow = deferred();
    const fn = jest.fn().mockReturnValueOnce(slow.promise).mockResolvedValue(undefined);

    task.start(fn, 1000);
    jest.advanceTimersByTime(10_000);

    slow.resolve();
    await flush();

    // One in-flight tick, not ten queued ones.
    expect(fn).toHaveBeenCalledTimes(1);
    await task.stop();
  });

  it('contains a throwing tick and keeps ticking', async () => {
    const task = new PeriodicTask('TEST', logger);
    const fn = jest
      .fn()
      .mockRejectedValueOnce(new Error('database unreachable'))
      .mockResolvedValue(undefined);

    task.start(fn, 1000);

    jest.advanceTimersByTime(1000);
    await flush();

    expect(logger.lines.some((l) => l.includes('database unreachable'))).toBe(true);

    jest.advanceTimersByTime(1000);
    expect(fn).toHaveBeenCalledTimes(2); // a failed sweep must not stop the loop

    await task.stop();
  });

  // ── The shutdown contract ────────────────────────────────────────────────

  it('stops ticking after stop()', async () => {
    const task = new PeriodicTask('TEST', logger);
    const fn = jest.fn().mockResolvedValue(undefined);

    task.start(fn, 1000);
    jest.advanceTimersByTime(1000);
    await task.stop();

    jest.advanceTimersByTime(10_000);
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it('AWAITS the in-flight tick instead of abandoning it', async () => {
    const task = new PeriodicTask('TEST', logger);
    const slow = deferred();
    let finished = false;
    const fn = jest.fn().mockReturnValue(slow.promise.then(() => void (finished = true)));

    task.start(fn, 1000);
    jest.advanceTimersByTime(1000);
    expect(task.isTicking).toBe(true);

    const stopping = task.stop(10_000);

    // Not resolved while the work is outstanding — this is the whole point.
    let stopped = false;
    void stopping.then(() => void (stopped = true));
    await Promise.resolve();
    expect(stopped).toBe(false);
    expect(finished).toBe(false);

    slow.resolve();
    await stopping;

    expect(finished).toBe(true);
  });

  it('gives up after the timeout rather than blocking shutdown forever', async () => {
    const task = new PeriodicTask('TEST', logger);
    const wedged = deferred(); // never resolves
    const fn = jest.fn().mockReturnValue(wedged.promise);

    task.start(fn, 1000);
    jest.advanceTimersByTime(1000);

    const stopping = task.stop(5000);
    jest.advanceTimersByTime(5000);
    await stopping; // resolves despite the tick never finishing

    expect(logger.lines.some((l) => l.startsWith('warn:') && l.includes('abandoning'))).toBe(true);
  });

  it('does not start new work once stopping', async () => {
    const task = new PeriodicTask('TEST', logger);
    const fn = jest.fn().mockResolvedValue(undefined);

    task.start(fn, 1000);
    await task.stop();

    // Even a timer that somehow fires after clearInterval finds the gate shut.
    jest.advanceTimersByTime(5000);
    expect(fn).not.toHaveBeenCalled();
  });

  it('stop() is safe when nothing is running', async () => {
    const task = new PeriodicTask('TEST', logger);
    await expect(task.stop()).resolves.toBeUndefined();

    task.start(jest.fn().mockResolvedValue(undefined), 1000);
    await task.stop();
    await expect(task.stop()).resolves.toBeUndefined(); // double stop
  });

  it('reports a drain in the logs so a slow shutdown is explicable', async () => {
    const task = new PeriodicTask('SWEEP', logger);
    const slow = deferred();
    task.start(() => slow.promise, 1000);

    jest.advanceTimersByTime(1000);
    const stopping = task.stop();
    slow.resolve();
    await stopping;

    expect(logger.lines.some((l) => l.includes('[SWEEP] draining'))).toBe(true);
    expect(logger.lines.some((l) => l.includes('[SWEEP] drained'))).toBe(true);
  });
});
