import { ForbiddenException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { EventsService } from '../events/events.service';
import { EventProcessorService } from '../events/event-processor.service';
import { EVENT_TYPES, EventType } from '../events/event.types';

function isDevEnv(): boolean {
  return (process.env.MPESA_ENV ?? 'sandbox') !== 'production';
}

function guardDev(logger: Logger, label: string): void {
  if (!isDevEnv()) {
    logger.error(`[DEV] ${label} called in production — BLOCKED`);
    throw new ForbiddenException(`${label} is not available in production.`);
  }
}

/**
 * DEV-ONLY service for test-harness operations.
 * Every method starts with guardDev() — all calls are no-ops in production.
 */
@Injectable()
export class DevService {
  private readonly logger = new Logger(DevService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly events: EventsService,
    private readonly processor: EventProcessorService,
  ) {}

  /**
   * Clear all pending/failed transactions, unprocessed events, and escrow rows
   * for a given post_id so the test can be repeated from scratch.
   */
  async resetState(postId: string): Promise<{
    ok: boolean;
    cleared: {
      transactions: number;
      escrow: number;
      events: number;
    };
  }> {
    guardDev(this.logger, 'reset-state');
    this.logger.warn(`[DEV] reset-state — post=${postId}`);

    // 1. Mark pending/failed transactions as dev_reset.
    const { data: txs } = await this.supabase.client
      .from('transactions')
      .update({ status: 'failed', failure_reason: 'dev_reset' })
      .eq('post_id', postId)
      .in('status', ['pending', 'failed'])
      .select('id');

    const txCount = txs?.length ?? 0;

    // 2. Delete pending/locked escrow rows for this post.
    const { data: esc } = await this.supabase.client
      .from('escrow')
      .delete()
      .eq('post_id', postId)
      .in('status', ['pending', 'locked'])
      .select('id');

    const escCount = esc?.length ?? 0;

    // 3. Mark unprocessed system_events for this post as dead_letter so the
    //    retry loop ignores them — avoids phantom replays after reset.
    const { data: evts } = await this.supabase.client
      .from('system_events')
      .update({ dead_letter: true, last_error: 'dev_reset' })
      .eq('entity_id', postId)
      .eq('processed', false)
      .select('id');

    const evtCount = evts?.length ?? 0;

    this.logger.warn(
      `[DEV] reset-state done — post=${postId} tx=${txCount} escrow=${escCount} events=${evtCount}`,
    );

    return {
      ok: true,
      cleared: { transactions: txCount, escrow: escCount, events: evtCount },
    };
  }

  /**
   * Inject any event type into the system and process it immediately.
   * Returns the event_id and the processor result.
   */
  async triggerEvent(
    type: string,
    postId: string,
    extraPayload: Record<string, unknown> = {},
  ): Promise<{ ok: boolean; eventId: string | null; message: string }> {
    guardDev(this.logger, 'trigger-event');

    const allTypes = Object.values(EVENT_TYPES) as string[];
    if (!allTypes.includes(type)) {
      throw new ForbiddenException(
        `Unknown event type "${type}". Valid: ${allTypes.join(', ')}`,
      );
    }

    this.logger.warn(`[DEV] trigger-event — type=${type} post=${postId}`);

    const eventId = await this.events.emit({
      type: type as EventType,
      entityType: 'post',
      entityId: postId,
      payload: { post_id: postId, ...extraPayload },
    });

    if (!eventId) {
      return { ok: false, eventId: null, message: 'Failed to insert event — check EVENTS logs.' };
    }

    // Process immediately without waiting for the 60s loop.
    await this.processor.replayById(eventId);

    return { ok: true, eventId, message: `Event ${type} emitted (id=${eventId}) and processed.` };
  }

  /**
   * Clear a stuck pending-transaction payment lock so a new STK push can be
   * initiated for the same post.
   */
  async resetPaymentLock(postId: string): Promise<{
    ok: boolean;
    cleared: number;
  }> {
    guardDev(this.logger, 'reset-payment-lock');
    this.logger.warn(`[DEV] reset-payment-lock — post=${postId}`);

    const { data: txs } = await this.supabase.client
      .from('transactions')
      .update({
        status: 'failed',
        failure_reason: 'dev_lock_reset',
        checkout_request_id: null,
      })
      .eq('post_id', postId)
      .eq('status', 'pending')
      .select('id');

    const count = txs?.length ?? 0;

    if (count === 0) {
      const { data: anyTx } = await this.supabase.client
        .from('transactions')
        .select('status')
        .eq('post_id', postId)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();

      if (!anyTx) throw new NotFoundException(`No transaction found for post ${postId}.`);

      this.logger.log(
        `[DEV] reset-payment-lock: no pending tx for post=${postId} (current status=${anyTx.status as string})`,
      );
    } else {
      this.logger.warn(`[DEV] reset-payment-lock: cleared ${count} pending tx(s) for post=${postId}`);
    }

    return { ok: true, cleared: count };
  }
}
