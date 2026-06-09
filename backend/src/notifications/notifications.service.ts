import { Injectable, Logger } from '@nestjs/common';
import axios from 'axios';
import { SupabaseService } from '../supabase/supabase.service';

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
  // Dispute resolution — names align with Flutter's lifecycleTypes routing.
  | 'dispute_resolved_release'   // admin: full release to provider
  | 'dispute_resolved_refund'    // admin: full refund to buyer
  | 'dispute_resolved_partial'   // admin: partial split
  // Escrow confirmed released (B2C callback success — previously missing).
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

  constructor(private readonly supabase: SupabaseService) {}

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
    const serverKey = process.env.FCM_SERVER_KEY;
    if (!serverKey) {
      this.logger.warn('[NOTIFY][FCM_SKIP] FCM_SERVER_KEY not configured — push skipped');
      return;
    }

    try {
      const { data: user } = await this.supabase.client
        .from('users')
        .select('fcm_tokens')
        .eq('id', payload.userId)
        .single();

      const tokens: string[] = Array.isArray(user?.fcm_tokens)
        ? (user.fcm_tokens as string[])
        : [];

      if (tokens.length === 0) {
        this.logger.log(`[NOTIFY][FCM_SKIP] no tokens for userId=${payload.userId} type=${payload.type}`);
        return;
      }

      await axios.post(
        'https://fcm.googleapis.com/fcm/send',
        {
          registration_ids: tokens,
          notification: { title: payload.title, body: payload.body },
          data: { type: payload.type, ...(payload.data ?? {}) },
        },
        {
          headers: {
            Authorization: `key=${serverKey}`,
            'Content-Type': 'application/json',
          },
        },
      );

      this.logger.log(`[NOTIFY][FCM_SENT] type=${payload.type} userId=${payload.userId} tokens=${tokens.length}`);
    } catch (err) {
      this.logger.error(
        `[NOTIFY][FCM_ERROR] type=${payload.type} userId=${payload.userId} — ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  }
}
