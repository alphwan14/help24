import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { SupabaseService } from '../../supabase/supabase.service';
import { DecisionsService } from './decisions.service';

/**
 * SLA monitor: a self-scheduled sweep (same setInterval pattern as
 * EventProcessorService — no @nestjs/schedule dependency) that auto-escalates
 * abandoned disputes so nothing rots silently in the queue.
 *
 * A case is "abandoned" when it has sat in open/reviewing past the SLA window
 * with no terminal decision. Each abandoned case gets a SYSTEM ESCALATE decision
 * (immutable ledger entry) and status='escalated'.
 */
const SWEEP_INTERVAL_MS = 30 * 60 * 1000; // every 30 minutes
const AUTO_ESCALATE_AFTER_DAYS = 3;
const NON_TERMINAL = ['open', 'reviewing', 'under_review'];

@Injectable()
export class DisputeSlaService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(DisputeSlaService.name);
  private timer?: ReturnType<typeof setInterval>;

  constructor(
    private readonly supabase: SupabaseService,
    private readonly decisions: DecisionsService,
  ) {}

  onModuleInit(): void {
    this.timer = setInterval(() => void this.sweep(), SWEEP_INTERVAL_MS);
    this.logger.log(`[SLA] monitor started — interval=30m escalateAfter=${AUTO_ESCALATE_AFTER_DAYS}d`);
  }

  onModuleDestroy(): void {
    if (this.timer) clearInterval(this.timer);
  }

  /** Find and escalate stale cases. Public so it can be triggered/tested manually. */
  async sweep(): Promise<{ escalated: number }> {
    const cutoff = new Date(Date.now() - AUTO_ESCALATE_AFTER_DAYS * 86_400_000).toISOString();

    const { data: stale, error } = await this.supabase.client
      .from('disputes')
      .select('id, created_at')
      .in('status', NON_TERMINAL)
      .lt('created_at', cutoff)
      .limit(50);

    if (error) {
      this.logger.error(`[SLA] sweep query failed: ${error.message}`);
      return { escalated: 0 };
    }
    if (!stale || stale.length === 0) return { escalated: 0 };

    let escalated = 0;
    for (const row of stale) {
      try {
        await this.decisions.systemEscalate(
          row.id as string,
          `No resolution within ${AUTO_ESCALATE_AFTER_DAYS} days of opening (SLA breach).`,
        );
        escalated += 1;
      } catch (err) {
        this.logger.error(
          `[SLA] failed to escalate ${row.id as string}: ${err instanceof Error ? err.message : String(err)}`,
        );
      }
    }

    this.logger.warn(`[SLA] sweep escalated ${escalated}/${stale.length} stale dispute(s)`);
    return { escalated };
  }
}
