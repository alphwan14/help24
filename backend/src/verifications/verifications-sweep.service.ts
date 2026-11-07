import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { PeriodicTask } from '../common/periodic-task';
import { SupabaseService } from '../supabase/supabase.service';
import { FILE_RETENTION_DAYS, VERIFICATION_BUCKET } from './verification-rules';

/**
 * The two time-driven parts of provider vetting (migration 135), every 10
 * minutes:
 *
 *   1. vetting_sweep() — hides offers whose 14-day notice (listings from before
 *      vetting) or pending-certificate window (30 days after a receipt was
 *      accepted) has run out, unless the author is verified by then.
 *   2. Deletes the document images 30 days after the decision (Data
 *      Protection Act 2019: keep personal data no longer than needed). The row
 *      stays as the record of the decision; files_deleted_at says when.
 *
 * Safe to run twice at once: the sweep is a database function that re-judges
 * from current state, and each purge is stamped only where still unstamped.
 * Removing an object that is already gone is not an error.
 *
 * Kill switch: VETTING_SWEEP_ENABLED=false.
 */
const SWEEP_INTERVAL_MS = 10 * 60 * 1000;
const PURGE_BATCH = 50;

export function vettingSweepEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return (env.VETTING_SWEEP_ENABLED ?? 'true').trim().toLowerCase() !== 'false';
}

@Injectable()
export class VerificationsSweepService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(VerificationsSweepService.name);
  private readonly task = new PeriodicTask('VETTING', this.logger);

  constructor(private readonly supabase: SupabaseService) {}

  onModuleInit(): void {
    if (!vettingSweepEnabled()) {
      this.logger.warn('[VETTING] sweep disabled (VETTING_SWEEP_ENABLED=false) — expired listings stay up, documents are kept');
      return;
    }
    this.task.start(async () => {
      await this.sweep();
    }, SWEEP_INTERVAL_MS);
    this.logger.log('[VETTING] sweep started — interval=10m');
  }

  async onModuleDestroy(): Promise<void> {
    await this.task.stop();
  }

  /** One pass. Public so a test or an operator can run it. */
  async sweep(now: Date = new Date()): Promise<{ hidden: number; purged: number }> {
    let hidden = 0;
    const { data, error } = await this.supabase.client.rpc('vetting_sweep');
    if (error) {
      this.logger.error(`[VETTING] vetting_sweep failed: ${error.message}`);
    } else {
      hidden = typeof data === 'number' ? data : Number(data ?? 0);
    }

    const purged = await this.purge(now);
    if (hidden || purged) this.logger.log(`[VETTING] sweep: listings_changed=${hidden} documents_deleted=${purged}`);
    return { hidden, purged };
  }

  private async purge(now: Date): Promise<number> {
    const cutoff = new Date(now.getTime() - FILE_RETENTION_DAYS * 86_400_000).toISOString();
    const { data, error } = await this.supabase.client
      .from('provider_verifications')
      .select('id, files')
      .in('status', ['approved', 'rejected'])
      .is('files_deleted_at', null)
      .lt('reviewed_at', cutoff)
      .order('reviewed_at', { ascending: true })
      .limit(PURGE_BATCH);
    if (error) {
      this.logger.error(`[VETTING] purge query failed: ${error.message}`);
      return 0;
    }

    let purged = 0;
    for (const row of (data ?? []) as Array<{ id: string; files: string[] | null }>) {
      try {
        const files = row.files ?? [];
        if (files.length) {
          const { error: rmErr } = await this.supabase.client.storage.from(VERIFICATION_BUCKET).remove(files);
          // Storage answers "not found" for an object already gone; anything
          // else leaves the row for the next sweep.
          if (rmErr && !/not.?found/i.test(rmErr.message ?? '')) {
            this.logger.warn(`[VETTING] purge id=${row.id} storage refused: ${rmErr.message}`);
            continue;
          }
        }
        const { error: upErr } = await this.supabase.client
          .from('provider_verifications')
          .update({ files_deleted_at: now.toISOString() })
          .eq('id', row.id)
          .is('files_deleted_at', null);
        if (upErr) {
          this.logger.warn(`[VETTING] purge id=${row.id} stamp failed: ${upErr.message}`);
          continue;
        }
        purged++;
      } catch (e) {
        this.logger.error(`[VETTING] purge id=${row.id} failed: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
    return purged;
  }
}
