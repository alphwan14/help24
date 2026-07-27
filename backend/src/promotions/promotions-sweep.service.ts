import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { PeriodicTask } from '../common/periodic-task';
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
  private readonly task = new PeriodicTask('PROMO][SWEEP', this.logger);

  constructor(private readonly campaigns: CampaignsService) {}

  onModuleInit(): void {
    this.task.start(() => this.tick(), SWEEP_INTERVAL_MS);
    this.logger.log('[PROMO][SWEEP][START] Lifecycle sweep started — interval=60s');
  }

  /**
   * Async so Nest AWAITS it. A campaign transitioning to expired mid-tick used
   * to be cut off by the shutdown signal; now the sweep finishes (or is given
   * up on after 10s) before the process goes.
   */
  async onModuleDestroy(): Promise<void> {
    await this.task.stop();
    this.logger.log('[PROMO][SWEEP][STOP] Lifecycle sweep cleared');
  }

  /**
   * Overlap prevention and error containment now live in PeriodicTask, which
   * applies them to all three sweeps rather than only to this one.
   */
  private async tick(): Promise<void> {
    await this.campaigns.sweepLifecycle();
  }
}
