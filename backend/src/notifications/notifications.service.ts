import { Injectable, Logger } from '@nestjs/common';
import { MulticastMessage } from 'firebase-admin/messaging';
import { SupabaseService } from '../supabase/supabase.service';
import { FirebaseAdminService } from './firebase-admin.service';

/**
 * Canonical notification type strings.
 * These MUST match the lifecycle routing set in mobile-app/lib/main.dart
 * (_onForegroundMessage / _onNotificationTap lifecycleTypes sets).
 */
export type NotificationType =
  | 'provider_applied'           // post author notified when someone applies
  | 'provider_selected'
  | 'payment_secured'
  | 'completion_requested'
  | 'job_approved'
  | 'payout_released'
  | 'dispute_opened'
  | 'dispute_resolved_release'
  | 'dispute_resolved_refund'
  | 'dispute_resolved_partial'
  | 'escrow_released';

export interface NotificationPayload {
  userId: string;
  type: NotificationType;
  title: string;
  body: string;
  data?: Record<string, string>;
}

@Injectable()
export class NotificationsService {
  private readonly logger = new Logger(NotificationsService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly firebaseAdmin: FirebaseAdminService,
  ) {}

  /**
   * Persist an in-app notification and fire a FCM push.
   * Both are best-effort — failures are logged but never bubble up.
   */
  async send(payload: NotificationPayload): Promise<void> {
    this.logger.log(`[NOTIFY][EVENT_RECEIVED] type=${payload.type} userId=${payload.userId}`);
    await Promise.all([
      this.persistInApp(payload),
      this.sendFcm(payload),
    ]);
  }

  /** Send to multiple users in parallel. */
  async sendMany(payloads: NotificationPayload[]): Promise<void> {
    await Promise.all(payloads.map((p) => this.send(p)));
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  private async persistInApp(payload: NotificationPayload): Promise<void> {
    this.logger.log(`[NOTIFY][DB_INSERT] type=${payload.type} userId=${payload.userId}`);
    const { error } = await this.supabase.client
      .from('notifications')
      .insert({
        user_id: payload.userId,
        type:    payload.type,
        title:   payload.title,
        body:    payload.body,
        data:    payload.data ?? {},
      });

    if (error) {
      this.logger.error(
        `[NOTIFY][DB_ERROR] type=${payload.type} userId=${payload.userId} — ${error.message}`,
      );
    } else {
      this.logger.log(`[NOTIFY][DB_SUCCESS] type=${payload.type} userId=${payload.userId}`);
    }
  }

  private async sendFcm(payload: NotificationPayload): Promise<void> {
    if (!this.firebaseAdmin.isReady) {
      this.logger.warn('[FCM][SKIP] Firebase Admin not initialized — push skipped');
      return;
    }

    const messaging = this.firebaseAdmin.getMessaging();
    if (!messaging) {
      this.logger.warn('[FCM][SKIP] getMessaging() returned null');
      return;
    }

    // 1. Read tokens from the dedicated fcm_tokens table.
    const { data: tokenRows } = await this.supabase.client
      .from('fcm_tokens')
      .select('token')
      .eq('user_id', payload.userId);

    let tokens: string[] = (tokenRows ?? [])
      .map((r: { token: string }) => r.token)
      .filter(Boolean);

    // 2. Fallback: legacy users.fcm_tokens JSONB (for devices that haven't updated yet).
    if (tokens.length === 0) {
      const { data: user } = await this.supabase.client
        .from('users')
        .select('fcm_tokens')
        .eq('id', payload.userId)
        .single();
      const legacy = Array.isArray(user?.fcm_tokens) ? (user.fcm_tokens as string[]) : [];
      tokens = legacy.filter(Boolean);
      if (tokens.length > 0) {
        this.logger.log(`[FCM][TOKEN_COUNT] userId=${payload.userId} source=legacy_jsonb count=${tokens.length}`);
      }
    }

    this.logger.log(
      `[FCM][TOKEN_COUNT] userId=${payload.userId} type=${payload.type} tokens=${tokens.length}`,
    );

    if (tokens.length === 0) {
      this.logger.log(`[FCM][SKIP] no registered tokens for userId=${payload.userId}`);
      return;
    }

    try {
      const message: MulticastMessage = {
        tokens,
        notification: { title: payload.title, body: payload.body },
        data: { type: payload.type, ...(payload.data ?? {}) },
        android: { priority: 'high' },
        apns: { payload: { aps: { sound: 'default', badge: 1 } } },
      };

      this.logger.log(
        `[FCM][SEND] type=${payload.type} userId=${payload.userId} tokens=${tokens.length}`,
      );

      const response = await messaging.sendEachForMulticast(message);

      this.logger.log(
        `[FCM][SUCCESS] type=${payload.type} successCount=${response.successCount} failureCount=${response.failureCount}`,
      );

      // Identify and remove invalid tokens so they don't clog future sends.
      const invalidTokens: string[] = [];
      response.responses.forEach((r, idx) => {
        if (!r.success) {
          const code = r.error?.code ?? 'unknown';
          this.logger.warn(
            `[FCM][FAILURE] token[${idx}] code=${code} msg=${r.error?.message ?? ''} userId=${payload.userId}`,
          );
          if (
            code === 'messaging/registration-token-not-registered' ||
            code === 'messaging/invalid-registration-token'
          ) {
            invalidTokens.push(tokens[idx]);
          }
        }
      });

      if (invalidTokens.length > 0) {
        this.logger.log(
          `[FCM][CLEANUP] removing ${invalidTokens.length} stale tokens for userId=${payload.userId}`,
        );
        await this.supabase.client
          .from('fcm_tokens')
          .delete()
          .eq('user_id', payload.userId)
          .in('token', invalidTokens);
      }
    } catch (err) {
      this.logger.error(
        `[FCM][ERROR] type=${payload.type} userId=${payload.userId} — ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  }
}
