import { BadRequestException, ConflictException, Injectable, Logger, NotFoundException, ServiceUnavailableException } from '@nestjs/common';
import { NotificationsService } from '../../notifications/notifications.service';
import { SupabaseService } from '../../supabase/supabase.service';
import { AdminContext } from '../auth/admin-role';

/** Most providers one call may notify — the dashboard shows the best 25. */
export const MAX_PER_CALL = 25;
/** A provider gets at most this many "request near you" pushes a day, from any admin. */
export const DAILY_CAP = 3;

export type SkipReason = 'is_client' | 'applied' | 'already_notified' | 'unavailable' | 'daily_limit' | 'no_account';

export interface RescueResult {
  notified: number;
  /** Of those notified, how many have a phone registered for push (the rest get it in their inbox). */
  withPush: number;
  skipped: Array<{ userId: string; reason: SkipReason }>;
}

const BLOCKED = new Set(['suspended', 'banned']);

/**
 * "Request rescue": an admin looking at an open request nobody has answered
 * tells the providers who could take it. The dashboard chooses WHO (its
 * provider matching); this service decides whether each of them may be told,
 * every time, whatever the caller sent:
 *
 *   - the listing is still an open, unassigned, live request;
 *   - never the client, never someone who already applied;
 *   - never a suspended or banned account;
 *   - once per provider per request, and at most DAILY_CAP a day — a push
 *     channel that nags is one people turn off.
 *
 * Each push is an ordinary notification row (type request_match, data
 * {listing_id, sent_by}) — which is also the record of who was told, by whom,
 * and when, and what the per-request and per-day limits are counted from.
 */
@Injectable()
export class RequestRescueService {
  private readonly logger = new Logger(RequestRescueService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly notifications: NotificationsService,
  ) {}

  private get db() {
    return this.supabase.client;
  }

  async notifyProviders(admin: AdminContext, postId: string, providerIds: string[]): Promise<RescueResult> {
    const ids = [...new Set(providerIds.filter((x) => typeof x === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(x)))];
    if (ids.length === 0) throw new BadRequestException('Choose at least one provider.');
    if (ids.length > MAX_PER_CALL) throw new BadRequestException(`At most ${MAX_PER_CALL} providers at a time.`);

    const { data: post, error: postError } = await this.db
      .from('posts')
      .select('id, title, location, category, type, status, archived_at, selected_provider_id, author_user_id')
      .eq('id', postId)
      .maybeSingle();
    if (postError) throw this.unavailable('listing', postError.message);
    if (!post) throw new NotFoundException('Listing not found.');
    if (post.type !== 'request' || post.status !== 'open' || post.selected_provider_id || post.archived_at) {
      throw new ConflictException('This request is no longer open, so nobody was notified.');
    }

    const since = new Date(Date.now() - 24 * 3600_000).toISOString();
    const [users, devices, states, applied, forThisPost, today] = await Promise.all([
      this.db.from('users').select('id, fcm_tokens').in('id', ids),
      // Where NotificationsService looks first; users.fcm_tokens is its fallback.
      this.db.from('fcm_tokens').select('user_id').in('user_id', ids),
      this.db.from('moderation_account_state').select('user_id, account_status').in('user_id', ids),
      this.db.from('applications').select('applicant_user_id').eq('post_id', postId).in('applicant_user_id', ids),
      this.db
        .from('notifications')
        .select('user_id')
        .eq('type', 'request_match')
        .or(`data->>listing_id.eq.${postId},data->>post_id.eq.${postId}`)
        .in('user_id', ids),
      this.db.from('notifications').select('user_id').eq('type', 'request_match').gte('created_at', since).in('user_id', ids),
    ]);
    for (const [r, what] of [[users, 'members'], [devices, 'devices'], [states, 'account standing'], [applied, 'applications'], [forThisPost, 'earlier notices'], [today, 'today\'s notices']] as const) {
      // Every limit below is read from these; a failed read must not be read as "no limit reached".
      if (r.error) throw this.unavailable(what, r.error.message);
    }

    const registered = new Set((devices.data ?? []).map((d) => d.user_id as string));
    const exists = new Map(
      (users.data ?? []).map((u) => [u.id as string, registered.has(u.id as string) || (Array.isArray(u.fcm_tokens) && u.fcm_tokens.length > 0)]),
    );
    const blocked = new Set((states.data ?? []).filter((s) => BLOCKED.has(s.account_status as string)).map((s) => s.user_id as string));
    const appliedIds = new Set((applied.data ?? []).map((a) => a.applicant_user_id as string));
    const toldHere = new Set((forThisPost.data ?? []).map((n) => n.user_id as string));
    const todayCount = new Map<string, number>();
    for (const n of today.data ?? []) todayCount.set(n.user_id as string, (todayCount.get(n.user_id as string) ?? 0) + 1);

    const skipped: RescueResult['skipped'] = [];
    const send: string[] = [];
    for (const id of ids) {
      const reason: SkipReason | null =
        !exists.has(id) ? 'no_account'
        : id === post.author_user_id ? 'is_client'
        : appliedIds.has(id) ? 'applied'
        : toldHere.has(id) ? 'already_notified'
        : blocked.has(id) ? 'unavailable'
        : (todayCount.get(id) ?? 0) >= DAILY_CAP ? 'daily_limit'
        : null;
      if (reason) skipped.push({ userId: id, reason });
      else send.push(id);
    }

    const title = 'A new request matches your work';
    const what = (post.title as string | null)?.trim() || 'Someone needs help';
    const where = (post.location as string | null)?.trim();
    const body = `${what}${where ? ` — ${where}` : ''}. Open Help24 to send an offer.`;

    await this.notifications.sendMany(
      send.map((userId) => ({
        userId,
        type: 'request_match' as const,
        title,
        body,
        // listing_id, not post_id: apps before 1.0.7 send an unknown type's
        // post_id to the job-lifecycle screen, which refuses everyone but the
        // client and the hired provider (a provider saw exactly that).
        data: { listing_id: postId, sent_by: admin.id },
        androidTag: `request_match_${postId}`,
      })),
    );

    const withPush = send.filter((id) => exists.get(id)).length;
    this.logger.log(
      `[RESCUE] post=${postId} notified=${send.length} push=${withPush} skipped=${skipped.length} by=${admin.email} (${admin.role})`,
    );
    return { notified: send.length, withPush, skipped };
  }

  private unavailable(what: string, message: string) {
    this.logger.error(`[RESCUE] ${what} unavailable: ${message}`);
    return new ServiceUnavailableException(`Could not check ${what} just now, so nobody was notified. Try again.`);
  }
}
