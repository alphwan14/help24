import { Injectable, Logger, NotFoundException, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { PeriodicTask } from '../common/periodic-task';
import { SupabaseService } from '../supabase/supabase.service';
import { NotificationsService } from '../notifications/notifications.service';
import { MpesaService } from '../mpesa/mpesa.service';
import { ReputationService } from '../reputation/reputation.service';
import { EventsService, SystemEventRow } from './events.service';
import { EVENT_TYPES, EventType } from './event.types';

const RETRY_INTERVAL_MS = 60_000; // retry loop cadence
const MAX_RETRIES       = 3;      // failures before dead_letter

/**
 * Escrow states where the money has already moved. An escrow row in one of
 * these is never re-pointed at another transaction, no matter what an event
 * says — see `lockEscrowForPayment`.
 */
const SETTLED_ESCROW_STATUSES = new Set(['released', 'refunded']);

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
  private readonly task = new PeriodicTask('PROCESSOR', this.logger);

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
    private readonly reputation: ReputationService,
  ) {}

  onModuleInit() {
    this._startedAt  = new Date();
    this._lastTickAt = new Date();
    this.task.start(() => this.retryUnprocessed(), RETRY_INTERVAL_MS);
    this.logger.log('[PROCESSOR][START] Retry loop started — interval=60s maxRetries=3');
  }

  /**
   * Async so Nest AWAITS it. This loop retries PAYOUT events — being cut off
   * mid-retry is how an event ends up marked attempted but never delivered, so
   * finishing the tick in progress matters more here than anywhere else.
   */
  async onModuleDestroy(): Promise<void> {
    await this.task.stop();
    this.logger.log('[PROCESSOR][STOP] Retry loop cleared');
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
    await this.lockEscrowForPayment(post_id, transaction_id, amount);

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
      // Find chat for deep-link routing in the push payload.
      const { data: psChat } = await this.supabase.client
        .from('chats')
        .select('id')
        .eq('post_id', post_id)
        .or(`user1.eq.${providerId},user2.eq.${providerId}`)
        .maybeSingle();
      const psChatId = (psChat?.id as string | null) ?? '';
      this.logger.log(`[PAYMENT_SECURED][NOTIFY] notifying provider=${providerId} post=${post_id} chatId=${psChatId || 'none'}`);
      await this.notifications.send({
        userId: providerId,
        type:   'payment_secured',
        title:  'Payment Secured',
        body:   `Funds for "${title}" are secured. Complete the job to receive your payout.`,
        data:   { post_id, transaction_id, ...(psChatId ? { chat_id: psChatId } : {}) },
      });
      this.logger.log(`[PAYMENT_SECURED][PUSH] sent to provider=${providerId}`);
    } else {
      this.logger.warn(
        `[PAYMENT_SECURED][NOTIFY] no selected_provider_id on post=${post_id} — payment_secured push skipped`,
      );
    }
  }

  /**
   * Ensure the post's escrow row exists and belongs to THIS transaction.
   *
   * WHY THIS IS NOT AN UPSERT ON `transaction_id`
   * ---------------------------------------------
   * It used to be, and it never once worked. `escrow` has no unique constraint
   * on `transaction_id` — its only unique constraint is `escrow_job_id_key
   * UNIQUE (post_id)` — so Postgres rejected every call with "there is no
   * unique or exclusion constraint matching the ON CONFLICT specification".
   * Six funded transactions reached production with their escrow row still
   * bound to a *failed* earlier attempt because of it.
   *
   * Adding a unique constraint on `transaction_id` does NOT fix this, and that
   * is worth stating because it is the obvious-looking repair: the INSERT would
   * then be valid SQL but would still violate `escrow_job_id_key`, because a
   * row for that post already exists under a different transaction. Verified
   * against production inside a rolled-back transaction.
   *
   * THE SHAPE OF THE BUG
   * --------------------
   *   1. attempt 1 → transaction + escrow row inserted optimistically
   *   2. attempt 1 fails → transaction is `failed`; the escrow row is LEFT
   *      BEHIND, still `locked`, still pointing at the failed transaction
   *   3. attempt 2 is allowed (initiate only blocks on `pending`/`paid`) → its
   *      optimistic insert dies on UNIQUE (post_id)
   *   4. attempt 2 succeeds → this handler was supposed to repair it
   *
   * Escrow is one-row-per-post BY SCHEMA, so the post is the identity that
   * matters and re-pointing the existing row is the correct repair.
   *
   * WHY IT IS EXPLICIT RATHER THAN `ON CONFLICT (post_id) DO UPDATE`
   * ---------------------------------------------------------------
   * A blind upsert would also overwrite `status` back to `locked`. Events are
   * replayable by hand (`POST /admin/events/replay`), and the eleven historical
   * `payment.success` events are sitting in dead-letter waiting to be replayed
   * — so a blind upsert could resurrect settled money as locked. Money code
   * gets to be explicit.
   */
  private async lockEscrowForPayment(
    postId: string,
    transactionId: string,
    amount: number,
  ): Promise<void> {
    const { data: existing, error: readError } = await this.supabase.client
      .from('escrow')
      .select('id, transaction_id, status')
      .eq('post_id', postId)
      .maybeSingle();

    if (readError) {
      throw new Error(`Escrow read failed for post ${postId}: ${readError.message}`);
    }

    // No escrow yet — the optimistic insert at initiate did not land.
    if (!existing) {
      const { error } = await this.supabase.client
        .from('escrow')
        .insert({ post_id: postId, transaction_id: transactionId, amount, status: 'locked' });

      if (error) {
        throw new Error(`Escrow insert failed for tx ${transactionId}: ${error.message}`);
      }
      return;
    }

    // Already ours. The common case, and a replay of this event.
    if (existing.transaction_id === transactionId) return;

    // Someone else's, and settled. Never resurrect money that has moved.
    if (SETTLED_ESCROW_STATUSES.has(existing.status as string)) {
      this.logger.warn(
        `[PAYMENT_SECURED][EVENT] post=${postId} already has ${existing.status} escrow ` +
          `(tx=${existing.transaction_id}); refusing to re-point to tx=${transactionId}`,
      );
      return;
    }

    // Someone else's and unsettled: re-point only when the incumbent
    // transaction actually failed. A live incumbent means two funded payments
    // for one post, which initiate is supposed to prevent — that is a state to
    // report, not to silently overwrite.
    const { data: incumbent } = await this.supabase.client
      .from('transactions')
      .select('status')
      .eq('id', existing.transaction_id)
      .maybeSingle();

    const incumbentStatus = (incumbent?.status as string | undefined) ?? null;
    if (incumbentStatus !== null && incumbentStatus !== 'failed') {
      this.logger.error(
        `[PAYMENT_SECURED][EVENT] post=${postId} escrow belongs to tx=${existing.transaction_id} ` +
          `in state '${incumbentStatus}'; refusing to re-point to tx=${transactionId}`,
      );
      return;
    }

    // `.eq('transaction_id', …)` is optimistic concurrency: if anything moved
    // the row between the read and this write, the update matches nothing
    // rather than clobbering it.
    const { error } = await this.supabase.client
      .from('escrow')
      .update({ transaction_id: transactionId, amount, status: 'locked' })
      .eq('id', existing.id)
      .eq('transaction_id', existing.transaction_id);

    if (error) {
      throw new Error(`Escrow re-point failed for tx ${transactionId}: ${error.message}`);
    }

    this.logger.log(
      `[PAYMENT_SECURED][EVENT] escrow re-pointed post=${postId} ` +
        `from failed tx=${existing.transaction_id} to tx=${transactionId}`,
    );
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

    // Look up chat for deep-link routing (both parties share the same chat).
    const { data: erChat } = await this.supabase.client
      .from('chats').select('id')
      .eq('post_id', post_id)
      .or(`user1.eq.${provider_id},user2.eq.${provider_id}`)
      .maybeSingle();
    const erChatId = (erChat?.id as string | null) ?? '';
    this.logger.log(`[PROCESSOR][HANDLE] escrow_released: notifying provider=${provider_id} buyer=${buyer_id} chatId=${erChatId || 'none'}`);

    await this.notifications.sendMany([
      {
        userId: provider_id,
        type: 'escrow_released',
        title: 'Payout Confirmed!',
        body: `Your M-Pesa payout for "${title}" has been sent. Check your M-Pesa messages.`,
        data: { post_id, transaction_id, ...(erChatId ? { chat_id: erChatId } : {}) },
      },
      {
        userId: buyer_id,
        type: 'escrow_released',
        title: 'Payment Complete',
        body: `The payment for "${title}" has been released to the provider.`,
        data: { post_id, transaction_id, ...(erChatId ? { chat_id: erChatId } : {}) },
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
    const { post_id, provider_id } = payload as { post_id: string; provider_id?: string };

    // Notifications sent inline by jobs.service.approve() — EventProcessor only
    // handles the payout initiation here (retryable B2C call).
    this.logger.log(`[PROCESSOR][HANDLE] job.approved: initiating payout post=${post_id}`);
    await this.handlePayoutRequested({ post_id });
    // Reputation: a successful completion changes completed-jobs + completion-rate.
    // Recompute from canonical data (idempotent, non-fatal).
    void this.reputation.recompute(provider_id);
    this.logger.log(`[PROCESSOR][HANDLE] job.approved: payout initiated post=${post_id}`);
  }

  private async handleJobDisputed(payload: Record<string, unknown>): Promise<void> {
    // Notifications sent inline by jobs.service.dispute() — EventProcessor handles
    // this event for audit/retry only, not for notification dispatch.
    // (Dispatching here would duplicate the inline notification already sent.)
    const { post_id, provider_id, client_user_id } = payload as {
      post_id: string; provider_id: string; client_user_id: string;
    };
    this.logger.log(
      `[PROCESSOR][HANDLE] job.disputed: audit-only post=${post_id} provider=${provider_id} client=${client_user_id}`,
    );
  }

  private async handleDisputeOpened(_payload: Record<string, unknown>): Promise<void> {
    // Audit-only — notifications handled by job.disputed.
  }

  // Dispute-resolution notifications are sent INLINE by DecisionsService.notifyParties()
  // (the same convention as job.approved / job.disputed). These handlers are therefore
  // AUDIT-ONLY — dispatching here would double-notify both parties for every ruling.
  // Dispute resolution changes the provider's dispute/open-dispute metrics, so each
  // handler recomputes reputation (idempotent, non-fatal). Notifications remain
  // inline in DecisionsService.notifyParties — these stay otherwise audit-only.
  private async handleDisputeResolvedRelease(payload: Record<string, unknown>): Promise<void> {
    const { post_id, provider_id } = payload as { post_id: string; provider_id?: string };
    void this.reputation.recompute(provider_id);
    this.logger.log(`[PROCESSOR][HANDLE] dispute.resolved_release: audit-only post=${post_id}`);
  }

  private async handleDisputeResolvedRefund(payload: Record<string, unknown>): Promise<void> {
    const { post_id, provider_id } = payload as { post_id: string; provider_id?: string };
    void this.reputation.recompute(provider_id);
    this.logger.log(`[PROCESSOR][HANDLE] dispute.resolved_refund: audit-only post=${post_id}`);
  }

  private async handleDisputeResolvedPartial(payload: Record<string, unknown>): Promise<void> {
    const { post_id, provider_id } = payload as { post_id: string; provider_id?: string };
    void this.reputation.recompute(provider_id);
    this.logger.log(`[PROCESSOR][HANDLE] dispute.resolved_partial: audit-only post=${post_id}`);
  }
}
