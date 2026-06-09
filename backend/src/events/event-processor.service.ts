import { Injectable, Logger, NotFoundException, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { NotificationsService } from '../notifications/notifications.service';
import { MpesaService } from '../mpesa/mpesa.service';
import { EventsService, SystemEventRow } from './events.service';
import { EVENT_TYPES, EventType } from './event.types';

const RETRY_INTERVAL_MS = 60_000; // retry loop cadence
const MAX_RETRIES       = 3;      // failures before dead_letter

/**
 * Log tag legend (grep these in Render logs):
 *
 *   [PROCESSOR][START]       — module initialized, loop running
 *   [PROCESSOR][TICK]        — retry loop fired; shows queue depth
 *   [PROCESSOR][PICK]        — about to process an event
 *   [PROCESSOR][HANDLE]      — handler started
 *   [PROCESSOR][SUCCESS]     — handler completed, event marked processed
 *   [PROCESSOR][FAILED]      — handler threw; retry_count incremented
 *   [PROCESSOR][DEAD_LETTER] — retry limit reached; event permanently failed
 *   [PROCESSOR][REPLAY]      — manual replay requested for an event
 *   [PROCESSOR][STOP]        — module destroyed, loop cleared
 */
@Injectable()
export class EventProcessorService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(EventProcessorService.name);
  private retryTimer?: ReturnType<typeof setInterval>;

  // In-memory health signals (reset on restart — intentional).
  private _startedAt      = new Date();
  private _lastTickAt     = new Date();
  private _lastProcessedAt: Date | null = null;
  private _tickCount      = 0;

  constructor(
    private readonly events: EventsService,
    private readonly supabase: SupabaseService,
    private readonly notifications: NotificationsService,
    private readonly mpesa: MpesaService,
  ) {}

  onModuleInit() {
    this._startedAt  = new Date();
    this._lastTickAt = new Date();
    this.retryTimer  = setInterval(() => {
      void this.retryUnprocessed();
    }, RETRY_INTERVAL_MS);
    this.logger.log('[PROCESSOR][START] Retry loop started — interval=60s maxRetries=3');
  }

  onModuleDestroy() {
    if (this.retryTimer) {
      clearInterval(this.retryTimer);
      this.logger.log('[PROCESSOR][STOP] Retry loop cleared');
    }
  }

  // ── Health status ─────────────────────────────────────────────────────────

  async getHealthStatus(): Promise<{
    processorAlive: boolean;
    startedAt: string;
    lastTickAt: string;
    lastProcessedAt: string | null;
    tickCount: number;
    queueSize: number;
    deadLetterCount: number;
  }> {
    const [queueSize, deadLetterCount] = await Promise.all([
      this.events.queueSize(),
      this.events.deadLetterCount(),
    ]);

    // Consider alive if the last tick was within 2× the retry interval.
    const aliveThresholdMs = RETRY_INTERVAL_MS * 2;
    const processorAlive = Date.now() - this._lastTickAt.getTime() < aliveThresholdMs;

    return {
      processorAlive,
      startedAt:       this._startedAt.toISOString(),
      lastTickAt:      this._lastTickAt.toISOString(),
      lastProcessedAt: this._lastProcessedAt?.toISOString() ?? null,
      tickCount:       this._tickCount,
      queueSize,
      deadLetterCount,
    };
  }

  // ── Replay (manual trigger) ────────────────────────────────────────────────

  async replayById(eventId: string): Promise<{ ok: boolean; message: string }> {
    this.logger.log(`[PROCESSOR][REPLAY] Manual replay requested for event_id=${eventId}`);

    const event = await this.events.fetchById(eventId);
    if (!event) throw new NotFoundException(`Event ${eventId} not found.`);

    // Reset dead_letter + retry_count so it can be re-queued.
    if (event.dead_letter || event.retry_count >= MAX_RETRIES) {
      await this.events.resetForReplay(eventId);
      this.logger.log(`[PROCESSOR][REPLAY] Reset dead_letter/retry for event_id=${eventId} type=${event.type}`);
    }

    // Process immediately.
    await this.runHandler(event, { isReplay: true });

    return { ok: true, message: `Event ${eventId} (${event.type}) replayed.` };
  }

  // ── Retry loop ─────────────────────────────────────────────────────────────

  private async retryUnprocessed(): Promise<void> {
    this._lastTickAt = new Date();
    this._tickCount++;

    const unprocessed = await this.events.fetchUnprocessed();

    this.logger.log(
      `[PROCESSOR][TICK] tick=${this._tickCount} queue=${unprocessed.length}`,
    );

    if (unprocessed.length === 0) return;

    for (const event of unprocessed) {
      await this.runHandler(event, { isReplay: false });
    }
  }

  // ── Core handler runner ────────────────────────────────────────────────────

  private async runHandler(
    event: SystemEventRow,
    opts: { isReplay: boolean },
  ): Promise<void> {
    const tag = opts.isReplay ? 'REPLAY' : 'PICK';
    this.logger.log(
      `[PROCESSOR][${tag}] id=${event.id} type=${event.type} retry=${event.retry_count}/${MAX_RETRIES}`,
    );

    this.logger.log(
      `[PROCESSOR][HANDLE] id=${event.id} type=${event.type}`,
    );

    try {
      await this.dispatch(event.type, event.payload);
      await this.events.markProcessed(event.id);
      this._lastProcessedAt = new Date();

      this.logger.log(
        `[PROCESSOR][SUCCESS] id=${event.id} type=${event.type} processed=true`,
      );
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : String(err);

      this.logger.error(
        `[PROCESSOR][FAILED] id=${event.id} type=${event.type} retry=${event.retry_count + 1}/${MAX_RETRIES} error="${errorMessage}"`,
      );

      const { isDead } = await this.events.markFailed(event.id, errorMessage, MAX_RETRIES);

      if (isDead) {
        this.logger.error(
          `[PROCESSOR][DEAD_LETTER] id=${event.id} type=${event.type} — max retries reached, use POST /admin/events/replay to retry manually`,
        );
      }
    }
  }

  // ── Dispatcher ─────────────────────────────────────────────────────────────

  private async dispatch(type: EventType, payload: Record<string, unknown>): Promise<void> {
    switch (type) {
      case EVENT_TYPES.PAYMENT_SUCCESS:
        return this.handlePaymentSuccess(payload);

      case EVENT_TYPES.PAYMENT_PAYOUT_REQUESTED:
        return this.handlePayoutRequested(payload);

      case EVENT_TYPES.ESCROW_RELEASED:
        return this.handleEscrowReleased(payload);

      case EVENT_TYPES.JOB_COMPLETION_REQUESTED:
        return this.handleJobCompletionRequested(payload);

      case EVENT_TYPES.JOB_APPROVED:
        return this.handleJobApproved(payload);

      case EVENT_TYPES.JOB_DISPUTED:
        return this.handleJobDisputed(payload);

      case EVENT_TYPES.DISPUTE_OPENED:
        return this.handleDisputeOpened(payload);

      case EVENT_TYPES.DISPUTE_RESOLVED_RELEASE:
        return this.handleDisputeResolvedRelease(payload);

      case EVENT_TYPES.DISPUTE_RESOLVED_REFUND:
        return this.handleDisputeResolvedRefund(payload);

      case EVENT_TYPES.DISPUTE_RESOLVED_PARTIAL:
        return this.handleDisputeResolvedPartial(payload);

      default:
        // Audit-only event — no side effects, just mark processed.
        break;
    }
  }

  // ── Handlers ───────────────────────────────────────────────────────────────

  private async handlePaymentSuccess(payload: Record<string, unknown>): Promise<void> {
    const { transaction_id, post_id, amount } = payload as {
      transaction_id: string;
      post_id: string;
      amount: number;
    };

    // 1. Lock escrow.
    const { error } = await this.supabase.client
      .from('escrow')
      .upsert(
        { post_id, transaction_id, amount, status: 'locked' },
        { onConflict: 'transaction_id' },
      );

    if (error) {
      throw new Error(`Escrow upsert failed for tx ${transaction_id}: ${error.message}`);
    }

    this.logger.log(`[PAYMENT_SECURED][EVENT] escrow locked tx=${transaction_id} post=${post_id}`);

    // 2. Notify the provider that funds are secured — this was previously missing.
    // The provider cannot start working until payment is locked, so this
    // notification is critical for the provider to know the job is funded.
    const { data: post } = await this.supabase.client
      .from('posts')
      .select('title, selected_provider_id')
      .eq('id', post_id)
      .maybeSingle();

    const providerId = post?.selected_provider_id as string | null;
    if (providerId) {
      const title = (post?.title as string | null) ?? 'your job';
      this.logger.log(`[PAYMENT_SECURED][NOTIFY] notifying provider=${providerId} post=${post_id}`);
      await this.notifications.send({
        userId: providerId,
        type:   'payment_secured',
        title:  'Payment Secured',
        body:   `Funds for "${title}" are secured. Complete the job to receive your payout.`,
        data:   { post_id, transaction_id },
      });
      this.logger.log(`[PAYMENT_SECURED][PUSH] sent to provider=${providerId}`);
    } else {
      this.logger.warn(
        `[PAYMENT_SECURED][NOTIFY] no selected_provider_id on post=${post_id} — payment_secured push skipped`,
      );
    }
  }

  private async handlePayoutRequested(payload: Record<string, unknown>): Promise<void> {
    const { post_id } = payload as { post_id: string };

    const { data: tx } = await this.supabase.client
      .from('transactions')
      .select('id, status')
      .eq('post_id', post_id)
      .in('status', ['paid', 'payout_pending', 'released'])
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (!tx) {
      this.logger.warn(`[PROCESSOR][HANDLE] payout_requested: no eligible tx for post=${post_id} — skipping`);
      return;
    }

    if (tx.status === 'payout_pending' || tx.status === 'released') {
      this.logger.log(`[PROCESSOR][HANDLE] payout_requested: tx=${tx.id as string} already ${tx.status as string} — idempotent skip`);
      return;
    }

    this.logger.log(`[PROCESSOR][HANDLE] payout_requested: calling releasePayout post=${post_id}`);
    await this.mpesa.releasePayout({ post_id });
    this.logger.log(`[PROCESSOR][HANDLE] payout_requested: B2C initiated post=${post_id}`);
  }

  private async handleEscrowReleased(payload: Record<string, unknown>): Promise<void> {
    const { transaction_id, post_id, post_title, provider_id, buyer_id } = payload as {
      transaction_id: string;
      post_id: string;
      post_title?: string;
      provider_id?: string;
      buyer_id?: string;
    };

    if (!provider_id || !buyer_id) {
      this.logger.warn(`[PROCESSOR][HANDLE] escrow_released: missing provider/buyer for tx=${transaction_id} — skipping`);
      return;
    }

    const title = post_title ?? 'your job';
    this.logger.log(`[PROCESSOR][HANDLE] escrow_released: notifying provider=${provider_id} buyer=${buyer_id}`);

    await this.notifications.sendMany([
      {
        userId: provider_id,
        type: 'escrow_released',
        title: 'Payout Confirmed!',
        body: `Your M-Pesa payout for "${title}" has been sent. Check your M-Pesa messages.`,
        data: { post_id, transaction_id },
      },
      {
        userId: buyer_id,
        type: 'escrow_released',
        title: 'Payment Complete',
        body: `The payment for "${title}" has been released to the provider.`,
        data: { post_id, transaction_id },
      },
    ]);
  }

  private async handleJobCompletionRequested(payload: Record<string, unknown>): Promise<void> {
    // Notification sent inline by jobs.service.markComplete() — EventProcessor
    // handles this event for audit/retry only, not for notification dispatch.
    const { post_id, completion_id } = payload as { post_id: string; completion_id: string };
    this.logger.log(
      `[PROCESSOR][HANDLE] job.completion_requested: audit-only post=${post_id} completion=${completion_id}`,
    );
  }

  private async handleJobApproved(payload: Record<string, unknown>): Promise<void> {
    const { post_id } = payload as { post_id: string };

    // Notifications sent inline by jobs.service.approve() — EventProcessor only
    // handles the payout initiation here (retryable B2C call).
    this.logger.log(`[PROCESSOR][HANDLE] job.approved: initiating payout post=${post_id}`);
    await this.handlePayoutRequested({ post_id });
    this.logger.log(`[PROCESSOR][HANDLE] job.approved: payout initiated post=${post_id}`);
  }

  private async handleJobDisputed(payload: Record<string, unknown>): Promise<void> {
    const { post_id, post_title, provider_id, client_user_id, dispute_id } = payload as {
      post_id: string;
      post_title: string;
      provider_id: string;
      client_user_id: string;
      dispute_id: string;
    };

    this.logger.log(`[PROCESSOR][HANDLE] job.disputed: notifying provider=${provider_id} client=${client_user_id}`);

    await this.notifications.sendMany([
      {
        userId: provider_id,
        type: 'dispute_opened',
        title: 'Dispute Opened',
        body: `The client has raised a dispute on "${post_title}". Funds are frozen pending admin review.`,
        data: { post_id, dispute_id },
      },
      {
        userId: client_user_id,
        type: 'dispute_opened',
        title: 'Dispute Submitted',
        body: `Your dispute on "${post_title}" has been submitted. Admin will review within 24-48 hours.`,
        data: { post_id, dispute_id },
      },
    ]);
  }

  private async handleDisputeOpened(_payload: Record<string, unknown>): Promise<void> {
    // Audit-only — notifications handled by job.disputed.
  }

  private async handleDisputeResolvedRelease(payload: Record<string, unknown>): Promise<void> {
    const { post_id, post_title, provider_id, buyer_id } = payload as {
      post_id: string; post_title: string; provider_id: string; buyer_id: string;
    };

    await this.notifications.sendMany([
      {
        userId: provider_id,
        type: 'dispute_resolved_release',
        title: 'Dispute Resolved — Payout Approved',
        body: `Admin reviewed "${post_title}" and released the full payment to you.`,
        data: { post_id },
      },
      {
        userId: buyer_id,
        type: 'dispute_resolved_release',
        title: 'Dispute Resolved',
        body: `Admin reviewed "${post_title}" and released payment to the provider.`,
        data: { post_id },
      },
    ]);
  }

  private async handleDisputeResolvedRefund(payload: Record<string, unknown>): Promise<void> {
    const { post_id, post_title, provider_id, buyer_id } = payload as {
      post_id: string; post_title: string; provider_id: string; buyer_id: string;
    };

    await this.notifications.sendMany([
      {
        userId: buyer_id,
        type: 'dispute_resolved_refund',
        title: 'Refund Approved',
        body: `Admin reviewed "${post_title}" and approved a full refund. You will receive your M-Pesa refund shortly.`,
        data: { post_id },
      },
      {
        userId: provider_id,
        type: 'dispute_resolved_refund',
        title: 'Dispute Resolved',
        body: `Admin reviewed "${post_title}" and issued a full refund to the client.`,
        data: { post_id },
      },
    ]);
  }

  private async handleDisputeResolvedPartial(payload: Record<string, unknown>): Promise<void> {
    const { post_id, post_title, provider_id, buyer_id, provider_amount, buyer_refund } = payload as {
      post_id: string; post_title: string; provider_id: string; buyer_id: string;
      provider_amount: number; buyer_refund: number;
    };

    await this.notifications.sendMany([
      {
        userId: provider_id,
        type: 'dispute_resolved_partial',
        title: 'Dispute Resolved — Partial Payment',
        body: `Admin split the payment for "${post_title}". You will receive KES ${provider_amount.toLocaleString()} via M-Pesa.`,
        data: { post_id, amount: String(provider_amount) },
      },
      {
        userId: buyer_id,
        type: 'dispute_resolved_partial',
        title: 'Dispute Resolved — Partial Refund',
        body: `Admin split the payment for "${post_title}". You will receive a refund of KES ${buyer_refund.toLocaleString()} via M-Pesa.`,
        data: { post_id, amount: String(buyer_refund) },
      },
    ]);
  }
}
