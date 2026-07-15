import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { CampaignsService } from './campaigns.service';

const SWEEP_INTERVAL_MS = 60_000;

/**
 * Campaign lifecycle sweep (EventProcessorService pattern): every 60 s,
 * active campaigns past ends_at → completed, unpaid campaigns past the
 * payment TTL → expired.
 *
 * Serving is correct-by-query (only active campaigns inside their window are
 * ever served), so a delayed or missed sweep can never over-serve — this loop
 * exists for truthful dashboards, notifications and analytics cut-offs.
 */
@Injectable()
export class PromotionsSweepService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(PromotionsSweepService.name);
  private timer?: ReturnType<typeof setInterval>;
  private running = false;

  constructor(private readonly campaigns: CampaignsService) {}

  onModuleInit(): void {
    this.timer = setInterval(() => {
      void this.tick();
    }, SWEEP_INTERVAL_MS);
    this.logger.log('[PROMO][SWEEP][START] Lifecycle sweep started — interval=60s');
  }

  onModuleDestroy(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.logger.log('[PROMO][SWEEP][STOP] Lifecycle sweep cleared');
    }
  }

  private async tick(): Promise<void> {
    if (this.running) return; // never overlap a slow sweep with the next tick
    this.running = true;
    try {
      await this.campaigns.sweepLifecycle();
    } catch (err) {
      this.logger.error(
        `[PROMO][SWEEP] tick failed: ${err instanceof Error ? err.message : err}`,
      );
    } finally {
      this.running = false;
    }
  }
}
