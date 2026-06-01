import { Injectable, Logger } from '@nestjs/common';
import axios from 'axios';
import { SupabaseService } from '../supabase/supabase.service';

/**
 * Canonical notification type strings.
 * These MUST match the lifecycle routing set in mobile-app/lib/main.dart
 * (_onForegroundMessage / _onNotificationTap lifecycleTypes sets).
 */
export type NotificationType =
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
        `[NOTIF] Failed to persist in-app notification for user ${payload.userId}: ${error.message}`,
      );
    }
  }

  private async sendFcm(payload: NotificationPayload): Promise<void> {
    const serverKey = process.env.FCM_SERVER_KEY;
    if (!serverKey) {
      this.logger.warn('[FCM] FCM_SERVER_KEY not set — push skipped');
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

      if (tokens.length === 0) return;

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

      this.logger.log(`[FCM] Sent "${payload.type}" to user ${payload.userId}`);
    } catch (err) {
      this.logger.error(
        `[FCM] Push failed for user ${payload.userId}: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  }
}
