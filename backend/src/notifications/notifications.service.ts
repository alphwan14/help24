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
  | 'chat_message'               // new message in a chat conversation
  | 'completion_requested'
  | 'job_approved'
  | 'payout_released'
  | 'dispute_opened'
  | 'dispute_resolved_release'
  | 'dispute_resolved_refund'
  | 'dispute_resolved_partial'
  | 'escrow_released'
  | 'review_requested'           // client prompted to review after approval
  | 'review_received';           // provider notified a review arrived

export interface NotificationPayload {
  userId: string;
  type: NotificationType;
  title: string;
  body: string;
  data?: Record<string, string>;
  /** Android notification tag — messages with the same tag replace the existing
   *  notification instead of stacking (use chatId to group per conversation). */
  androidTag?: string;
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
    const { data: tokenRows, error: tokenErr } = await this.supabase.client
      .from('fcm_tokens')
      .select('token')
      .eq('user_id', payload.userId);

    if (tokenErr) {
      this.logger.error(
        `[FCM][TOKEN_QUERY_ERROR] fcm_tokens query failed for userId=${payload.userId} — ${tokenErr.message} (code=${tokenErr.code})`,
      );
    }

    // Dedupe: a device that re-registered can leave duplicate token rows, which
    // would send the same push twice. Set() collapses them to one delivery.
    let tokens: string[] = [
      ...new Set(
        (tokenRows ?? []).map((r: { token: string }) => r.token).filter(Boolean),
      ),
    ];

    this.logger.log(
      `[FCM][TOKENS_TABLE] userId=${payload.userId} rows=${tokenRows?.length ?? 0} valid=${tokens.length}`,
    );

    // 2. Fallback: legacy users.fcm_tokens JSONB (for devices that haven't updated yet).
    if (tokens.length === 0) {
      const { data: user, error: legacyErr } = await this.supabase.client
        .from('users')
        .select('fcm_tokens')
        .eq('id', payload.userId)
        .single();
      if (legacyErr) {
        this.logger.warn(
          `[FCM][LEGACY_QUERY_ERROR] users.fcm_tokens query failed for userId=${payload.userId} — ${legacyErr.message}`,
        );
      }
      const legacy = Array.isArray(user?.fcm_tokens) ? (user.fcm_tokens as string[]) : [];
      tokens = legacy.filter(Boolean);
      this.logger.log(
        `[FCM][LEGACY_TOKENS] userId=${payload.userId} legacy_count=${legacy.length} valid=${tokens.length}`,
      );
    }

    this.logger.log(
      `[FCM][TOKEN_COUNT] userId=${payload.userId} type=${payload.type} tokens=${tokens.length}`,
    );

    if (tokens.length === 0) {
      this.logger.log(`[FCM][SKIP] no registered tokens for userId=${payload.userId}`);
      return;
    }

    try {
      // Chat messages use data-only on Android so the Flutter background isolate
      // can display MessagingStyle (accumulated thread).  If we include an
      // android.notification field, the FCM SDK auto-displays using `tag`
      // replacement — each new message wipes the previous one from the tray.
      // Data-only messages trigger onBackgroundMessage() where Flutter builds
      // the full MessagingStyle notification from its persistent cache.
      //
      // iOS still needs a visible push; we supply it via apns.payload.aps.alert
      // so the user receives a banner regardless of app state.
      const isChatMessage = payload.type === 'chat_message';

      const message: MulticastMessage = {
        tokens,

        // Top-level notification: used by iOS and as fallback for non-chat events.
        // Omitted for chat on Android (handled by background isolate instead).
        ...(!isChatMessage
          ? { notification: { title: payload.title, body: payload.body } }
          : {}),

        data: {
          type: payload.type,
          // Embed human-readable fields in data so the background isolate can
          // read them without a separate DB query.
          ...(isChatMessage
            ? { sender_name: payload.title, message_preview: payload.body }
            : {}),
          ...(payload.data ?? {}),
        },

        android: {
          priority: 'high',
          // Chat: no android.notification → no auto-display → background isolate takes over.
          // Other events: standard channel + optional tag-based replacement.
          ...(!isChatMessage
            ? {
                notification: {
                  channelId: 'help24_high_importance',
                  sound: 'default',
                  ...(payload.androidTag ? { tag: payload.androidTag } : {}),
                },
              }
            : {}),
        },

        apns: {
          payload: {
            aps: {
              // iOS banner for all notification types including chat.
              alert: { title: payload.title, body: payload.body },
              sound: 'default',
              badge: 1,
              // content-available lets iOS wake the app for background processing.
              ...(isChatMessage ? { 'content-available': 1 } : {}),
            },
          },
        },
      };

      // For chat, assert the payload carries NO notification block on any layer —
      // Android must never auto-display; the Flutter background isolate is the
      // sole renderer. This log makes a regression here obvious in production.
      if (isChatMessage) {
        this.logger.log(
          `[FCM][CHAT_DATA_ONLY] userId=${payload.userId} ` +
          `topLevelNotification=${'notification' in message} ` +
          `androidNotification=${!!(message.android && 'notification' in message.android)} ` +
          `emitter=nestjs`,
        );
      }

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

  // ── Chat message notifications ─────────────────────────────────────────────

  /**
   * Called by NotificationsController POST /notifications/chat-message.
   * Looks up the chat's participants, resolves the recipient, inserts a bell
   * notification, and fires an FCM push tagged with chatId (Android groups all
   * messages from the same conversation into a single notification slot).
   */
  async sendChatNotification(params: {
    chatId: string;
    senderId: string;
    messagePreview: string;
  }): Promise<{ ok: boolean; message: string }> {
    this.logger.log(
      `[NOTIFY][CHAT_DB_INSERT] chatId=${params.chatId} senderId=${params.senderId}`,
    );

    // 1. Resolve recipient from chat participants.
    const { data: chat, error: chatErr } = await this.supabase.client
      .from('chats')
      .select('user1, user2, post_id')
      .eq('id', params.chatId)
      .single();

    if (chatErr || !chat) {
      this.logger.warn(`[NOTIFY][CHAT_DB_INSERT] chat not found chatId=${params.chatId} — ${chatErr?.message ?? 'null row'}`);
      return { ok: false, message: 'Chat not found' };
    }

    const user1 = chat.user1 as string;
    const user2 = chat.user2 as string;

    if (params.senderId !== user1 && params.senderId !== user2) {
      this.logger.warn(
        `[NOTIFY][CHAT_DB_INSERT] sender=${params.senderId} is not a participant of chat=${params.chatId}`,
      );
      return { ok: false, message: 'Sender is not a participant of this chat' };
    }

    const recipientId = params.senderId === user1 ? user2 : user1;
    const postId      = chat.post_id as string | null;

    // 2. Resolve BOTH participant display names in one query so we can label
    //    every message in the thread (not just the latest sender).
    const { data: participants } = await this.supabase.client
      .from('users')
      .select('id, name')
      .in('id', [user1, user2]);

    const nameById: Record<string, string> = {};
    for (const p of participants ?? []) {
      nameById[p.id as string] = ((p.name as string | null) ?? '').trim() || 'Someone';
    }
    const senderName = nameById[params.senderId] ?? 'Someone';

    // 3. Build the recent thread server-side and ship it in the payload.
    //    This makes Android MessagingStyle threading DETERMINISTIC — the
    //    background isolate renders the thread straight from this array
    //    instead of an unreliable cross-isolate SharedPreferences cache
    //    (which silently fails to accumulate on many devices, causing each
    //    new push to replace the previous one instead of expanding it).
    const previewFor = (content: unknown, mtype: unknown): string => {
      const c = typeof content === 'string' ? content.trim() : '';
      if (c) return c.slice(0, 100);
      switch (mtype) {
        case 'image':    return '📷 Photo';
        case 'file':     return '📎 File';
        case 'location': return '📍 Location';
        default:         return 'Message';
      }
    };

    const { data: recent } = await this.supabase.client
      .from('chat_messages')
      .select('sender_id, content, type, created_at, deleted_for_everyone')
      .eq('chat_id', params.chatId)
      .order('created_at', { ascending: false })
      .limit(7);

    // Oldest→newest, skip soft-deleted, denormalise sender name + epoch ms.
    const thread = (recent ?? [])
      .filter((m) => m.deleted_for_everyone !== true)
      .reverse()
      .map((m) => ({
        s:  nameById[m.sender_id as string] ?? 'Someone',
        t:  previewFor(m.content, m.type),
        ts: new Date(m.created_at as string).getTime(),
      }));

    // 4. Send bell notification + FCM push to recipient.
    const preview = params.messagePreview.slice(0, 100);

    this.logger.log(
      `[NOTIFY][CHAT_BELL_CREATED] recipientId=${recipientId} senderName=${senderName} chatId=${params.chatId} threadLen=${thread.length}`,
    );

    await this.send({
      userId: recipientId,
      type:   'chat_message',
      title:  senderName,
      body:   preview,
      data: {
        chat_id:   params.chatId,
        sender_id: params.senderId,
        // Full recent thread for MessagingStyle (JSON, ~1KB — well under FCM's 4KB).
        thread:    JSON.stringify(thread),
        // Emitter fingerprint: lets the Flutter client tell a legitimate push
        // (this backend, current build) apart from any push emitted by STALE
        // code — e.g. a Render deployment still running the pre-data-only build,
        // which sends a notification block and no emitter. A chat push missing
        // these fields is logged client-side as [FCM][FOREIGN_EMITTER].
        emitter:         'nestjs',
        emitter_version: 'v2',
        emitter_service: 'help24-api',
        ...(postId ? { post_id: postId } : {}),
      },
      androidTag: params.chatId, // same tag → Android replaces existing notification
    });

    return { ok: true, message: 'Chat notification sent' };
  }
}
