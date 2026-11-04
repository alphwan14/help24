import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { PeriodicTask } from '../common/periodic-task';
import { SupabaseService } from '../supabase/supabase.service';
import { NotificationsService } from '../notifications/notifications.service';
import { JobsService } from './jobs.service';
import {
  autoApproveEnabled,
  autoApproveHours,
  dueAction,
  kenyaTime,
  type PendingCompletionClock,
} from './auto-approval';

/**
 * A completed job the client never answers approves itself (migration 134).
 *
 * Every 5 minutes: remind the client halfway through the review window and
 * 4 hours before it ends, then approve when it ends — through
 * JobsService.approveCompletion, the same transition as the client's own
 * Approve, so the payout follows the same evented, retried, audited path.
 * Self-scheduled with PeriodicTask like the dispute SLA sweep (no
 * @nestjs/schedule dependency).
 *
 * SAFE TO RUN TWICE AT ONCE. PeriodicTask stops a slow sweep overlapping
 * itself inside one process, but a second instance has its own loop. So
 * every write here is CONDITIONAL — a reminder is claimed by stamping its
 * column only where it is still null and the completion still pending, and
 * approval moves the row only where it is still 'pending_approval'. Whoever
 * gets the row acts; everyone else does nothing.
 *
 * A DISPUTE STOPS ALL OF IT. Raising a dispute moves the completion to
 * 'disputed' (DisputesService.freezeForDispute), and every query and write
 * here requires 'pending_approval'. If the dispute lands after approval, the
 * payout's own claim on the payment ('paid' → 'payout_pending') loses to the
 * freeze and nothing is sent.
 *
 * Kill switch: AUTO_APPROVE_ENABLED=false. Window: AUTO_APPROVE_HOURS (48).
 */
const SWEEP_INTERVAL_MS = 5 * 60 * 1000;
const BATCH = 100;

type Row = PendingCompletionClock & {
  id: string;
  post_id: string;
  client_user_id: string;
  provider_user_id: string;
};

@Injectable()
export class CompletionAutoApprovalService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(CompletionAutoApprovalService.name);
  private readonly task = new PeriodicTask('AUTO_APPROVE', this.logger);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly jobs: JobsService,
    private readonly notifications: NotificationsService,
  ) {}

  onModuleInit(): void {
    if (!autoApproveEnabled()) {
      this.logger.warn('[AUTO_APPROVE] disabled (AUTO_APPROVE_ENABLED=false) — completions wait for the client');
      return;
    }
    this.task.start(async () => {
      await this.sweep();
    }, SWEEP_INTERVAL_MS);
    this.logger.log(`[AUTO_APPROVE] sweep started — interval=5m window=${autoApproveHours()}h`);
  }

  /** Async so Nest awaits it: an approval cut in half is a job nobody is watching. */
  async onModuleDestroy(): Promise<void> {
    await this.task.stop();
  }

  /** One pass. Public so a test (or an operator) can run it with a fixed clock. */
  async sweep(now: Date = new Date()): Promise<{ approved: number; reminded: number }> {
    const { data, error } = await this.supabase.client
      .from('job_completions')
      .select('id, post_id, client_user_id, provider_user_id, created_at, auto_approve_at, first_reminder_sent_at, final_reminder_sent_at')
      .eq('status', 'pending_approval')
      .not('auto_approve_at', 'is', null)
      .order('auto_approve_at', { ascending: true })
      .limit(BATCH);
    if (error) {
      this.logger.error(`[AUTO_APPROVE] query failed: ${error.message}`);
      return { approved: 0, reminded: 0 };
    }

    let approved = 0;
    let reminded = 0;
    for (const row of (data ?? []) as Row[]) {
      const action = dueAction(row, now);
      try {
        if (action === 'approve') {
          if (await this.approve(row)) approved++;
        } else if (action === 'first_reminder' || action === 'final_reminder') {
          if (await this.remind(row, action, now)) reminded++;
        }
      } catch (err) {
        // One bad row must not stop the rest; the next sweep retries it.
        this.logger.error(
          `[AUTO_APPROVE] completion=${row.id} ${action} failed: ${err instanceof Error ? err.message : String(err)}`,
        );
      }
    }
    if (approved || reminded) {
      this.logger.log(`[AUTO_APPROVE] sweep: approved=${approved} reminded=${reminded}`);
    }
    return { approved, reminded };
  }

  private async post(postId: string) {
    const { data } = await this.supabase.client
      .from('posts')
      .select('id, title, author_user_id, selected_provider_id')
      .eq('id', postId)
      .maybeSingle();
    return data as { id: string; title: string; author_user_id: string; selected_provider_id: string | null } | null;
  }

  private async approve(row: Row): Promise<boolean> {
    const post = await this.post(row.post_id);
    // The completion names who did the work. If the listing no longer agrees
    // (provider changed, post gone), paying anyone automatically is wrong:
    // leave it pending for the admin overdue alert.
    if (!post || post.selected_provider_id !== row.provider_user_id || post.author_user_id !== row.client_user_id) {
      this.logger.warn(`[AUTO_APPROVE] completion=${row.id} skipped — post no longer matches the completion`);
      return false;
    }

    const won = await this.jobs.approveCompletion({
      completionId: row.id,
      postId: post.id,
      postTitle: post.title,
      providerId: row.provider_user_id,
      clientUserId: row.client_user_id,
      by: 'system',
    });
    if (!won) return false;

    const hours = autoApproveHours();
    await this.notifications.sendMany([
      {
        userId: row.provider_user_id,
        type: 'payout_released',
        title: 'Job approved',
        body: `"${post.title}" was approved automatically after ${hours} hours. Your M-Pesa payout is being processed.`,
        data: { post_id: post.id },
      },
      {
        userId: row.client_user_id,
        type: 'job_approved',
        title: 'Job approved automatically',
        body: `You didn't approve or dispute "${post.title}" within ${hours} hours, so it was approved and the provider is being paid.`,
        data: { post_id: post.id },
      },
    ]);
    return true;
  }

  private async remind(row: Row, which: 'first_reminder' | 'final_reminder', now: Date): Promise<boolean> {
    const column = which === 'first_reminder' ? 'first_reminder_sent_at' : 'final_reminder_sent_at';

    // Claim the reminder before sending it: of two sweeps, one gets the row.
    // A push that then fails is a reminder lost, never one sent twice.
    const { data: claimed, error } = await this.supabase.client
      .from('job_completions')
      .update({ [column]: now.toISOString() })
      .eq('id', row.id)
      .eq('status', 'pending_approval')
      .is(column, null)
      .select('id');
    if (error) throw new Error(`reminder claim failed: ${error.message}`);
    if (!claimed || claimed.length === 0) return false;

    const post = await this.post(row.post_id);
    const title = post?.title ?? 'your job';
    const when = kenyaTime(row.auto_approve_at as string);
    await this.notifications.send({
      userId: row.client_user_id,
      // The same type as "Job Marked as Done", so a tap opens the same
      // approve-or-dispute screen on every app version.
      type: 'completion_requested',
      ...(which === 'first_reminder'
        ? {
            title: 'Please review the job',
            body: `Your provider marked "${title}" as done. Approve it, or open a dispute if something is wrong. It approves automatically on ${when}.`,
          }
        : {
            title: 'Final reminder: 4 hours left',
            body: `"${title}" approves automatically at ${when} and the provider is paid. If something is wrong, open a dispute in the app before then.`,
          }),
      data: { post_id: row.post_id, completion_id: row.id },
    });
    return true;
  }
}
