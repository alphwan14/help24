import { ForbiddenException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { EventsService } from '../events/events.service';
import { EventProcessorService } from '../events/event-processor.service';
import { EVENT_TYPES, EventType } from '../events/event.types';
import { FirebaseAdminService } from '../notifications/firebase-admin.service';
import { MulticastMessage } from 'firebase-admin/messaging';

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
    private readonly firebaseAdmin: FirebaseAdminService,
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

  /**
   * Isolation test: send a test FCM push directly to a user's registered tokens
   * (or to a raw token string if provided).  This bypasses the full notification
   * pipeline so you can confirm that Firebase Admin SDK + device tokens work
   * independently of the event/notification service.
   *
   * POST /dev/test-fcm
   * Body: { "userId": "string", "token"?: "raw FCM token to bypass DB lookup" }
   */
  async testFcm(
    userId: string,
    rawToken?: string,
  ): Promise<{
    ok: boolean;
    firebaseReady: boolean;
    tokensSource: string;
    tokens: string[];
    successCount: number;
    failureCount: number;
    results: Array<{ token: string; success: boolean; errorCode?: string; errorMessage?: string }>;
    message: string;
  }> {
    guardDev(this.logger, 'test-fcm');
    this.logger.warn(`[DEV][TEST_FCM] userId=${userId} rawToken=${rawToken ? rawToken.slice(0, 16) + '…' : 'none'}`);

    const firebaseReady = this.firebaseAdmin.isReady;
    if (!firebaseReady) {
      this.logger.error('[DEV][TEST_FCM] Firebase Admin not initialized — check FIREBASE_* env vars on Render');
      return {
        ok: false,
        firebaseReady: false,
        tokensSource: 'none',
        tokens: [],
        successCount: 0,
        failureCount: 0,
        results: [],
        message: 'Firebase Admin not initialized. Set FIREBASE_PROJECT_ID, FIREBASE_CLIENT_EMAIL, FIREBASE_PRIVATE_KEY in Render env vars.',
      };
    }

    let tokens: string[] = [];
    let tokensSource = 'raw';

    if (rawToken && rawToken.trim().length > 0) {
      tokens = [rawToken.trim()];
      this.logger.log(`[DEV][TEST_FCM] using raw token provided in request body`);
    } else {
      // 1. Query fcm_tokens table.
      const { data: rows, error: rowErr } = await this.supabase.client
        .from('fcm_tokens')
        .select('token, platform, updated_at')
        .eq('user_id', userId);

      if (rowErr) {
        this.logger.error(`[DEV][TEST_FCM] fcm_tokens query error — ${rowErr.message} (code=${rowErr.code})`);
      } else {
        this.logger.log(`[DEV][TEST_FCM] fcm_tokens rows for userId=${userId}: ${JSON.stringify(rows ?? [])}`);
      }

      tokens = (rows ?? []).map((r: { token: string }) => r.token).filter(Boolean);

      // 2. Fallback: legacy users.fcm_tokens JSONB.
      if (tokens.length === 0) {
        const { data: user, error: legErr } = await this.supabase.client
          .from('users')
          .select('fcm_tokens')
          .eq('id', userId)
          .single();

        if (legErr) {
          this.logger.warn(`[DEV][TEST_FCM] users.fcm_tokens query error — ${legErr.message}`);
        } else {
          this.logger.log(`[DEV][TEST_FCM] users.fcm_tokens for userId=${userId}: ${JSON.stringify(user?.fcm_tokens)}`);
        }

        const legacy = Array.isArray(user?.fcm_tokens) ? (user.fcm_tokens as string[]) : [];
        tokens = legacy.filter(Boolean);
        tokensSource = tokens.length > 0 ? 'legacy_jsonb' : 'none';
      } else {
        tokensSource = 'fcm_tokens_table';
      }
    }

    this.logger.log(`[DEV][TEST_FCM] tokens found: ${tokens.length} (source=${tokensSource})`);

    if (tokens.length === 0) {
      return {
        ok: false,
        firebaseReady: true,
        tokensSource: 'none',
        tokens: [],
        successCount: 0,
        failureCount: 0,
        results: [],
        message: `No FCM tokens found for userId=${userId}. Pass "token" in the body to test with a raw token, or ensure the device has registered.`,
      };
    }

    const messaging = this.firebaseAdmin.getMessaging()!;
    const message: MulticastMessage = {
      tokens,
      notification: {
        title: '🔔 TEST PUSH',
        body: 'If you see this, FCM is working end-to-end.',
      },
      data: { type: 'test', userId },
      android: {
        priority: 'high',
        notification: { channelId: 'help24_high_importance', sound: 'default' },
      },
      apns: { payload: { aps: { sound: 'default', badge: 1 } } },
    };

    this.logger.log(`[DEV][TEST_FCM] sending to ${tokens.length} token(s) via sendEachForMulticast`);

    try {
      const response = await messaging.sendEachForMulticast(message);
      this.logger.log(
        `[DEV][TEST_FCM] done — successCount=${response.successCount} failureCount=${response.failureCount}`,
      );

      const results = response.responses.map((r, idx) => {
        const entry = {
          token: tokens[idx].slice(0, 20) + '…',
          success: r.success,
          errorCode: r.error?.code,
          errorMessage: r.error?.message,
        };
        if (!r.success) {
          this.logger.warn(
            `[DEV][TEST_FCM] token[${idx}] FAILED — code=${entry.errorCode} msg=${entry.errorMessage}`,
          );
        }
        return entry;
      });

      return {
        ok: response.successCount > 0,
        firebaseReady: true,
        tokensSource,
        tokens: tokens.map((t) => t.slice(0, 20) + '…'),
        successCount: response.successCount,
        failureCount: response.failureCount,
        results,
        message: response.successCount > 0
          ? `Push sent to ${response.successCount}/${tokens.length} device(s). Check your physical device.`
          : `All ${tokens.length} send(s) failed — see results[].errorCode for details.`,
      };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      this.logger.error(`[DEV][TEST_FCM] sendEachForMulticast threw — ${msg}`);
      return {
        ok: false,
        firebaseReady: true,
        tokensSource,
        tokens: tokens.map((t) => t.slice(0, 20) + '…'),
        successCount: 0,
        failureCount: tokens.length,
        results: tokens.map((t) => ({ token: t.slice(0, 20) + '…', success: false, errorCode: 'exception', errorMessage: msg })),
        message: `sendEachForMulticast threw: ${msg}`,
      };
    }
  }
}
