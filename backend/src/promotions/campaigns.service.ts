import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { EventsService } from '../events/events.service';
import { EVENT_TYPES } from '../events/event.types';
import { NotificationsService } from '../notifications/notifications.service';
import { PackagesService } from './packages.service';
import { PromotionSettingsService } from './settings.service';
import {
  CampaignStatus,
  assertTransition,
  daysRemaining,
  isTerminal,
  shiftedEndOnResume,
} from './campaign-state';

export interface PromotionCampaignRow {
  id: string;
  owner_user_id: string;
  subject_type: 'post' | 'provider';
  post_id: string | null;
  post_title: string | null;
  package_id: string;
  package_name: string;
  price_kes: number;
  duration_days: number;
  placements: string[];
  status: CampaignStatus;
  starts_at: string | null;
  ends_at: string | null;
  paused_at: string | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
  rejection_reason: string | null;
  cancelled_at: string | null;
  cancel_reason: string | null;
  created_at: string;
  updated_at: string;
}

const CAMPAIGN_COLUMNS =
  'id, owner_user_id, subject_type, post_id, post_title, package_id, package_name, price_kes, ' +
  'duration_days, placements, status, starts_at, ends_at, paused_at, reviewed_by, reviewed_at, ' +
  'rejection_reason, cancelled_at, cancel_reason, created_at, updated_at';

/** Embedded relations for list/detail responses. */
const CAMPAIGN_DETAIL_SELECT =
  `${CAMPAIGN_COLUMNS}, posts(id, title, category, status, archived_at), ` +
  'promotion_payments(id, status, amount_kes, phone, mpesa_receipt, failure_reason, paid_at, created_at)';

@Injectable()
export class CampaignsService {
  private readonly logger = new Logger(CampaignsService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly packages: PackagesService,
    private readonly settings: PromotionSettingsService,
    private readonly events: EventsService,
    private readonly notifications: NotificationsService,
  ) {}

  // ── Shared helpers ──────────────────────────────────────────────────────────

  private withDerived<T extends PromotionCampaignRow>(row: T) {
    return {
      ...row,
      days_remaining: daysRemaining(row.ends_at ? new Date(row.ends_at) : null, new Date()),
    };
  }

  private async load(campaignId: string): Promise<PromotionCampaignRow> {
    const { data, error } = await this.supabase.client
      .from('promotion_campaigns')
      .select(CAMPAIGN_COLUMNS)
      .eq('id', campaignId)
      .maybeSingle();

    if (error) throw new Error(`Failed to load campaign ${campaignId}: ${error.message}`);
    if (!data) throw new NotFoundException(`Campaign ${campaignId} not found.`);
    return data as unknown as PromotionCampaignRow;
  }

  private assertOwned(campaign: PromotionCampaignRow, userId: string): void {
    if (!userId || campaign.owner_user_id !== userId) {
      throw new ForbiddenException('This campaign belongs to another account.');
    }
  }

  /**
   * The ONLY writer of campaign.status. Validates via the pure state machine,
   * then updates with optimistic concurrency (`eq status = from`) so a racing
   * sweep/admin/owner action can never double-apply a transition.
   */
  private async transition(
    campaign: PromotionCampaignRow,
    to: CampaignStatus,
    patch: Record<string, unknown> = {},
  ): Promise<PromotionCampaignRow> {
    try {
      assertTransition(campaign.status, to);
    } catch (err) {
      throw new ConflictException(err instanceof Error ? err.message : String(err));
    }

    const { data, error } = await this.supabase.client
      .from('promotion_campaigns')
      .update({ status: to, updated_at: new Date().toISOString(), ...patch })
      .eq('id', campaign.id)
      .eq('status', campaign.status)
      .select(CAMPAIGN_COLUMNS)
      .maybeSingle();

    if (error) throw new Error(`Campaign ${campaign.id} transition failed: ${error.message}`);
    if (!data) {
      throw new ConflictException(
        `Campaign changed state while processing ('${campaign.status}' → '${to}' no longer applies). Refresh and retry.`,
      );
    }

    this.logger.log(`[PROMO][CAMPAIGN] ${campaign.id}: ${campaign.status} → ${to}`);
    return data as unknown as PromotionCampaignRow;
  }

  // ── Create ──────────────────────────────────────────────────────────────────

  /**
   * "Promote Business" entry point: campaign for an OWNED, OPEN offer post.
   * Created directly in awaiting_payment — the one-minute flow is
   * choose package → review → pay; 'draft' stays reserved for future builders.
   */
  async create(params: { userId: string; postId: string; packageId: string }) {
    const { userId, postId, packageId } = params;

    const { data: post, error: postError } = await this.supabase.client
      .from('posts')
      .select('id, title, type, status, archived_at, author_user_id')
      .eq('id', postId)
      .maybeSingle();

    if (postError) throw new Error(`Failed to load post ${postId}: ${postError.message}`);
    if (!post) throw new NotFoundException('The listing you want to promote no longer exists.');
    if (post.author_user_id !== userId) {
      throw new ForbiddenException('You can only promote your own listings.');
    }
    if (post.type !== 'offer') {
      throw new BadRequestException(
        'Only service listings (offers) can be promoted right now.',
      );
    }
    if (post.archived_at || post.status !== 'open') {
      throw new BadRequestException('Only open, visible listings can be promoted.');
    }

    const pkg = await this.packages.getActive(packageId);
    if (pkg.is_custom || pkg.price_kes == null) {
      throw new BadRequestException(
        'Enterprise promotions are arranged with the Help24 team — contact support to set one up.',
      );
    }

    const { data, error } = await this.supabase.client
      .from('promotion_campaigns')
      .insert({
        owner_user_id: userId,
        subject_type: 'post',
        post_id: postId,
        post_title: post.title,
        package_id: pkg.id,
        package_name: pkg.name,
        price_kes: pkg.price_kes,
        duration_days: pkg.duration_days,
        placements: pkg.placements,
        status: 'awaiting_payment',
      })
      .select(CAMPAIGN_COLUMNS)
      .single();

    if (error) {
      if (error.code === '23505') {
        throw new ConflictException('This listing already has a promotion in progress.');
      }
      throw new Error(`Failed to create campaign: ${error.message}`);
    }

    const campaign = data as unknown as PromotionCampaignRow;

    void this.events.emit({
      type: EVENT_TYPES.PROMOTION_CAMPAIGN_CREATED,
      actorUserId: userId,
      entityType: 'promotion_campaign',
      entityId: campaign.id,
      payload: { post_id: postId, package_id: pkg.id, price_kes: pkg.price_kes },
    });

    return this.withDerived(campaign);
  }

  // ── Owner reads ─────────────────────────────────────────────────────────────

  async listByOwner(userId: string) {
    const { data, error } = await this.supabase.client
      .from('promotion_campaigns')
      .select(CAMPAIGN_DETAIL_SELECT)
      .eq('owner_user_id', userId)
      .order('created_at', { ascending: false })
      .limit(100);

    if (error) throw new Error(`Failed to list campaigns: ${error.message}`);
    return ((data ?? []) as unknown as (PromotionCampaignRow & Record<string, unknown>)[]).map((row) =>
      this.withDerived(row),
    );
  }

  async getOwned(campaignId: string, userId: string) {
    const { data, error } = await this.supabase.client
      .from('promotion_campaigns')
      .select(CAMPAIGN_DETAIL_SELECT)
      .eq('id', campaignId)
      .maybeSingle();

    if (error) throw new Error(`Failed to load campaign ${campaignId}: ${error.message}`);
    if (!data) throw new NotFoundException(`Campaign ${campaignId} not found.`);
    const campaign = data as unknown as PromotionCampaignRow & Record<string, unknown>;
    this.assertOwned(campaign, userId);
    return this.withDerived(campaign);
  }

  // ── Owner commands ──────────────────────────────────────────────────────────

  async pause(campaignId: string, userId: string) {
    const campaign = await this.load(campaignId);
    this.assertOwned(campaign, userId);
    const updated = await this.transition(campaign, 'paused', {
      paused_at: new Date().toISOString(),
    });

    void this.events.emit({
      type: EVENT_TYPES.PROMOTION_PAUSED,
      actorUserId: userId,
      entityType: 'promotion_campaign',
      entityId: campaignId,
    });
    return this.withDerived(updated);
  }

  async resume(campaignId: string, userId: string) {
    const campaign = await this.load(campaignId);
    this.assertOwned(campaign, userId);
    if (campaign.status !== 'paused' || !campaign.paused_at || !campaign.ends_at) {
      throw new ConflictException('Only a paused campaign can be resumed.');
    }

    const now = new Date();
    const newEnd = shiftedEndOnResume(new Date(campaign.ends_at), new Date(campaign.paused_at), now);
    const updated = await this.transition(campaign, 'active', {
      ends_at: newEnd.toISOString(),
      paused_at: null,
    });

    void this.events.emit({
      type: EVENT_TYPES.PROMOTION_RESUMED,
      actorUserId: userId,
      entityType: 'promotion_campaign',
      entityId: campaignId,
      payload: { ends_at: newEnd.toISOString() },
    });
    return this.withDerived(updated);
  }

  async cancel(campaignId: string, userId: string, reason?: string) {
    const campaign = await this.load(campaignId);
    this.assertOwned(campaign, userId);
    if (isTerminal(campaign.status)) {
      throw new ConflictException('This campaign has already ended.');
    }

    const updated = await this.transition(campaign, 'cancelled', {
      cancelled_at: new Date().toISOString(),
      cancel_reason: reason?.slice(0, 500) ?? 'Cancelled by owner',
    });

    void this.events.emit({
      type: EVENT_TYPES.PROMOTION_CANCELLED,
      actorUserId: userId,
      entityType: 'promotion_campaign',
      entityId: campaignId,
      payload: { reason: updated.cancel_reason },
    });
    return this.withDerived(updated);
  }

  // ── Payment hook (called by PromotionPaymentsService on confirmed payment) ──

  /**
   * awaiting_payment → pending_review, or straight → active when moderation
   * auto_approve is on (the future verified-business fast path — a settings
   * flip, not a code change). Idempotent: a replayed callback on a campaign
   * already past awaiting_payment is a logged no-op.
   */
  async onPaymentSuccess(campaignId: string): Promise<void> {
    const campaign = await this.load(campaignId);
    if (campaign.status !== 'awaiting_payment') {
      this.logger.log(
        `[PROMO][CAMPAIGN] payment success for ${campaignId} in status '${campaign.status}' — no transition needed`,
      );
      return;
    }

    const moderation = await this.settings.moderation();
    if (moderation.auto_approve) {
      await this.activateInternal(campaign, 'auto_approve');
      return;
    }

    await this.transition(campaign, 'pending_review');
    void this.notifications.send({
      userId: campaign.owner_user_id,
      type: 'promotion_payment_received',
      title: 'Payment received ✓',
      body: `Your ${campaign.package_name} promotion for "${campaign.post_title ?? 'your listing'}" is being reviewed. It usually goes live within a few hours.`,
      data: { campaign_id: campaignId },
    });
  }

  /** Shared activation: sets the serving window and notifies the owner. */
  private async activateInternal(
    campaign: PromotionCampaignRow,
    reviewedBy: string,
  ): Promise<PromotionCampaignRow> {
    const now = new Date();
    const endsAt = new Date(now.getTime() + campaign.duration_days * 24 * 60 * 60 * 1000);

    const updated = await this.transition(campaign, 'active', {
      starts_at: now.toISOString(),
      ends_at: endsAt.toISOString(),
      paused_at: null,
      reviewed_by: reviewedBy,
      reviewed_at: now.toISOString(),
    });

    void this.events.emit({
      type: EVENT_TYPES.PROMOTION_ACTIVATED,
      entityType: 'promotion_campaign',
      entityId: campaign.id,
      payload: { ends_at: endsAt.toISOString(), reviewed_by: reviewedBy },
    });

    void this.notifications.send({
      userId: campaign.owner_user_id,
      type: 'promotion_live',
      title: 'Your promotion is live 🎉',
      body: `"${campaign.post_title ?? 'Your listing'}" is now featured across Help24 for ${campaign.duration_days} days.`,
      data: { campaign_id: campaign.id },
    });

    return updated;
  }

  // ── Admin (moderation + oversight) ──────────────────────────────────────────

  async adminList(status?: CampaignStatus, limit = 100) {
    let query = this.supabase.client
      .from('promotion_campaigns')
      .select(`${CAMPAIGN_DETAIL_SELECT}, users!owner_user_id(name, email)`)
      .order('created_at', { ascending: false })
      .limit(Math.min(limit, 200));

    if (status) query = query.eq('status', status);

    const { data, error } = await query;
    if (error) throw new Error(`Failed to list campaigns (admin): ${error.message}`);
    return ((data ?? []) as unknown as (PromotionCampaignRow & Record<string, unknown>)[]).map((row) =>
      this.withDerived(row),
    );
  }

  async adminGet(campaignId: string) {
    const { data, error } = await this.supabase.client
      .from('promotion_campaigns')
      .select(`${CAMPAIGN_DETAIL_SELECT}, users!owner_user_id(name, email)`)
      .eq('id', campaignId)
      .maybeSingle();

    if (error) throw new Error(`Failed to load campaign ${campaignId}: ${error.message}`);
    if (!data) throw new NotFoundException(`Campaign ${campaignId} not found.`);
    return this.withDerived(data as unknown as PromotionCampaignRow & Record<string, unknown>);
  }

  async approve(campaignId: string, adminId: string) {
    const campaign = await this.load(campaignId);
    if (campaign.status !== 'pending_review') {
      throw new ConflictException(
        `Only campaigns pending review can be approved (current: '${campaign.status}').`,
      );
    }
    if (!campaign.post_id) {
      throw new ConflictException('The promoted listing was deleted — reject or cancel instead.');
    }
    const updated = await this.activateInternal(campaign, adminId);
    return this.withDerived(updated);
  }

  async reject(campaignId: string, adminId: string, reason: string) {
    const campaign = await this.load(campaignId);
    const updated = await this.transition(campaign, 'rejected', {
      reviewed_by: adminId,
      reviewed_at: new Date().toISOString(),
      rejection_reason: reason.slice(0, 500),
    });

    void this.events.emit({
      type: EVENT_TYPES.PROMOTION_REJECTED,
      entityType: 'promotion_campaign',
      entityId: campaignId,
      payload: { reason, reviewed_by: adminId },
    });

    void this.notifications.send({
      userId: campaign.owner_user_id,
      type: 'promotion_rejected',
      title: 'Promotion not approved',
      body: `Your promotion for "${campaign.post_title ?? 'your listing'}" was not approved: ${reason}. Contact support for help with a refund.`,
      data: { campaign_id: campaignId },
    });

    return this.withDerived(updated);
  }

  /** Admin pause — same transition as the owner's, without the ownership gate. */
  async adminPause(campaignId: string, adminId: string) {
    const campaign = await this.load(campaignId);
    const updated = await this.transition(campaign, 'paused', {
      paused_at: new Date().toISOString(),
    });

    void this.events.emit({
      type: EVENT_TYPES.PROMOTION_PAUSED,
      entityType: 'promotion_campaign',
      entityId: campaignId,
      payload: { paused_by: adminId },
    });
    return this.withDerived(updated);
  }

  /** Admin resume — shifts ends_at by the pause duration, like the owner path. */
  async adminResume(campaignId: string, adminId: string) {
    const campaign = await this.load(campaignId);
    if (campaign.status !== 'paused' || !campaign.paused_at || !campaign.ends_at) {
      throw new ConflictException('Only a paused campaign can be resumed.');
    }

    const now = new Date();
    const newEnd = shiftedEndOnResume(new Date(campaign.ends_at), new Date(campaign.paused_at), now);
    const updated = await this.transition(campaign, 'active', {
      ends_at: newEnd.toISOString(),
      paused_at: null,
    });

    void this.events.emit({
      type: EVENT_TYPES.PROMOTION_RESUMED,
      entityType: 'promotion_campaign',
      entityId: campaignId,
      payload: { ends_at: newEnd.toISOString(), resumed_by: adminId },
    });
    return this.withDerived(updated);
  }

  async adminCancel(campaignId: string, adminId: string, reason: string) {
    const campaign = await this.load(campaignId);
    if (isTerminal(campaign.status)) {
      throw new ConflictException('This campaign has already ended.');
    }
    const updated = await this.transition(campaign, 'cancelled', {
      cancelled_at: new Date().toISOString(),
      cancel_reason: `[admin] ${reason}`.slice(0, 500),
    });

    void this.events.emit({
      type: EVENT_TYPES.PROMOTION_CANCELLED,
      entityType: 'promotion_campaign',
      entityId: campaignId,
      payload: { reason, cancelled_by: adminId },
    });
    return this.withDerived(updated);
  }

  // ── Lifecycle sweep (called by PromotionsSweepService every 60 s) ───────────

  /**
   * Tidies statuses; serving is already correct-by-query (only active campaigns
   * inside their window are ever served), so the sweep can never over-serve —
   * it exists for accurate dashboards, notifications and analytics cut-offs.
   */
  async sweepLifecycle(): Promise<{ completed: number; expired: number }> {
    const nowIso = new Date().toISOString();
    let completed = 0;
    let expired = 0;

    // 1. Active campaigns past their end → completed (+ owner notification).
    const { data: overdue, error: overdueError } = await this.supabase.client
      .from('promotion_campaigns')
      .select(CAMPAIGN_COLUMNS)
      .eq('status', 'active')
      .lte('ends_at', nowIso)
      .limit(100);

    if (overdueError) {
      this.logger.error(`[PROMO][SWEEP] overdue query failed: ${overdueError.message}`);
    } else {
      for (const row of (overdue ?? []) as unknown as PromotionCampaignRow[]) {
        try {
          await this.transition(row, 'completed');
          completed++;

          void this.events.emit({
            type: EVENT_TYPES.PROMOTION_COMPLETED,
            entityType: 'promotion_campaign',
            entityId: row.id,
          });
          void this.notifications.send({
            userId: row.owner_user_id,
            type: 'promotion_completed',
            title: 'Promotion completed',
            body: `Your ${row.package_name} promotion for "${row.post_title ?? 'your listing'}" has finished. Check your results in Promote Business.`,
            data: { campaign_id: row.id },
          });
        } catch (err) {
          // Concurrent transition (owner cancelled at the same moment) — fine.
          this.logger.warn(
            `[PROMO][SWEEP] complete skipped for ${row.id}: ${err instanceof Error ? err.message : err}`,
          );
        }
      }
    }

    // 2. Unpaid campaigns past the payment TTL → expired (quiet — no push).
    const payment = await this.settings.payment();
    const cutoff = new Date(Date.now() - payment.awaiting_payment_ttl_hours * 60 * 60 * 1000);

    const { data: stale, error: staleError } = await this.supabase.client
      .from('promotion_campaigns')
      .select(CAMPAIGN_COLUMNS)
      .in('status', ['draft', 'awaiting_payment'])
      .lte('created_at', cutoff.toISOString())
      .limit(100);

    if (staleError) {
      this.logger.error(`[PROMO][SWEEP] stale query failed: ${staleError.message}`);
    } else {
      for (const row of (stale ?? []) as unknown as PromotionCampaignRow[]) {
        try {
          await this.transition(row, 'expired');
          expired++;
          void this.events.emit({
            type: EVENT_TYPES.PROMOTION_EXPIRED,
            entityType: 'promotion_campaign',
            entityId: row.id,
          });
        } catch (err) {
          this.logger.warn(
            `[PROMO][SWEEP] expire skipped for ${row.id}: ${err instanceof Error ? err.message : err}`,
          );
        }
      }
    }

    if (completed || expired) {
      this.logger.log(`[PROMO][SWEEP] completed=${completed} expired=${expired}`);
    }
    return { completed, expired };
  }
}
