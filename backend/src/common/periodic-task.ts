import { Logger } from '@nestjs/common';

/**
 * A `setInterval` loop that can be stopped without cutting work in half.
 *
 * Three services run background sweeps — event retry, promotions lifecycle,
 * dispute SLA — and each had hand-rolled the same loop slightly differently.
 * The differences were the problem:
 *
 *   * only PromotionsSweepService guarded against OVERLAP, so a retry sweep or
 *     an SLA sweep that ran longer than its interval had a second copy start
 *     on top of it, both writing the same rows;
 *   * every `onModuleDestroy` was a synchronous `clearInterval`. That stops the
 *     NEXT tick, but Nest re-raises the shutdown signal as soon as the
 *     synchronous hooks return — so a tick already in flight (escalating a
 *     dispute, expiring a campaign, retrying a payout event) was terminated
 *     mid-write anyway. Enabling shutdown hooks made the intervals stop
 *     cleanly and did nothing at all for the work in progress.
 *
 * This is the one implementation of that loop, so fixing it once fixes it
 * everywhere.
 *
 * CONTRACT
 * --------
 *   start()  begins ticking; a tick is skipped (not queued) while the previous
 *            one is still running, and skipped entirely once stopping.
 *   stop()   clears the interval and AWAITS the in-flight tick, bounded by
 *            `timeoutMs`. Returns when the work is done or the bound expires —
 *            never later, so a wedged sweep cannot hold the process open until
 *            the orchestrator resorts to SIGKILL.
 *
 * A tick that throws is logged and swallowed: a background sweep failing must
 * never take the process down, and the next tick is a natural retry.
 */
export class PeriodicTask {
  private timer?: ReturnType<typeof setInterval>;
  private inFlight?: Promise<void>;
  private stopping = false;

  /**
   * @param name  identifies this loop in logs (e.g. 'PROMO][SWEEP').
   * @param logger the owning service's logger, so output keeps its prefix.
   */
  constructor(
    private readonly name: string,
    private readonly logger: Logger,
  ) {}

  /** True while a tick is executing. */
  get isTicking(): boolean {
    return this.inFlight !== undefined;
  }

  start(fn: () => Promise<void>, intervalMs: number): void {
    if (this.timer) return; // idempotent — double-init must not double-tick
    this.stopping = false;
    this.timer = setInterval(() => this.tick(fn), intervalMs);
  }

  private tick(fn: () => Promise<void>): void {
    // Never overlap a slow sweep with the next one, and never begin new work
    // during shutdown — a tick that starts here could not finish before the
    // signal is re-raised.
    if (this.stopping || this.inFlight) return;

    this.inFlight = fn()
      .catch((err: unknown) => {
        this.logger.error(
          `[${this.name}] tick failed: ${err instanceof Error ? err.message : String(err)}`,
        );
      })
      .finally(() => {
        this.inFlight = undefined;
      });
  }

  /**
   * Stop ticking and wait for any tick already running.
   *
   * `timeoutMs` defaults to 10 s, comfortably inside the 30 s grace period that
   * `docker stop`, `docker compose down` and a Render redeploy all allow before
   * SIGKILL. The bound exists so shutdown stays predictable even if a sweep is
   * blocked on a hung database call.
   */
  async stop(timeoutMs = 10_000): Promise<void> {
    this.stopping = true;
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = undefined;
    }

    const running = this.inFlight;
    if (!running) return;

    this.logger.log(`[${this.name}] draining in-flight tick…`);

    let timer: ReturnType<typeof setTimeout> | undefined;
    const expired = new Promise<'timeout'>((resolve) => {
      timer = setTimeout(() => resolve('timeout'), timeoutMs);
      // unref so this timer is never itself the reason the process stays alive.
      timer.unref?.();
    });

    try {
      const outcome = await Promise.race([running.then(() => 'done' as const), expired]);
      if (outcome === 'timeout') {
        this.logger.warn(
          `[${this.name}] tick still running after ${timeoutMs}ms — abandoning it to shut down`,
        );
      } else {
        this.logger.log(`[${this.name}] drained`);
      }
    } finally {
      if (timer) clearTimeout(timer);
    }
  }
}
