import { ForbiddenException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { daysRemaining } from './campaign-state';

/**
 * Promotion analytics.
 *
 * Ingest: raw events are appended to promotion_events (the ONLY canonical
 * data), then fn_recompute_promotion_daily_stats re-derives each touched
 * (campaign, Nairobi-day) cell idempotently — no "+1" counters anywhere, so a
 * retried client batch can never double-count a day (055 house style).
 *
 * Dashboard: answers the owner's one question — "is promoting my business
 * working?" — from the derived daily rollup.
 */

export const PROMOTION_EVENT_TYPES = [
  'impression',
  'click',
  'profile_view',
  'phone_tap',
  'whatsapp_tap',
  'message',
  'booking',
] as const;
export type PromotionEventType = (typeof PROMOTION_EVENT_TYPES)[number];

export const PROMOTION_EVENT_PLACEMENTS = [
  'discover',
  'search',
  'category',
  'nearby',
  'profile',
] as const;

export interface PromotionEventInput {
  campaign_id: string;
  event_type: PromotionEventType;
  placement?: string | null;
  viewer_user_id?: string | null;
}

interface DailyStatsRow {
  campaign_id: string;
  day: string;
  impressions_discover: number;
  impressions_search: number;
  impressions_category: number;
  impressions_nearby: number;
  clicks: number;
  profile_views: number;
  phone_taps: number;
  whatsapp_taps: number;
  messages: number;
  bookings: number;
}

/** Nairobi is fixed UTC+3 (no DST) — a business owner's "today" is theirs. */
export function nairobiDayOf(date: Date): string {
  return new Date(date.getTime() + 3 * 60 * 60 * 1000).toISOString().slice(0, 10);
}

@Injectable()
export class PromotionAnalyticsService {
  private readonly logger = new Logger(PromotionAnalyticsService.name);

  constructor(private readonly supabase: SupabaseService) {}

  // ── Ingest (POST /promotions/events — batched, fire-and-forget client) ─────

  /**
   * Accepts a client batch, drops rows referencing unknown campaigns (a
   * deleted campaign must not 500 the whole batch), inserts the survivors,
   * then recomputes today's rollup for each touched campaign.
   */
  async ingest(events: PromotionEventInput[]): Promise<{ accepted: number; dropped: number }> {
    if (events.length === 0) return { accepted: 0, dropped: 0 };

    const campaignIds = [...new Set(events.map((e) => e.campaign_id))];
    const { data: known, error: knownError } = await this.supabase.client
      .from('promotion_campaigns')
      .select('id')
      .in('id', campaignIds);

    if (knownError) throw new Error(`Failed to validate campaigns: ${knownError.message}`);
    const knownIds = new Set(((known ?? []) as Array<{ id: string }>).map((r) => r.id));

    const rows = events
      .filter((e) => knownIds.has(e.campaign_id))
      .map((e) => ({
        campaign_id: e.campaign_id,
        event_type: e.event_type,
        placement: e.placement ?? null,
        viewer_user_id: e.viewer_user_id ?? null,
      }));

    const dropped = events.length - rows.length;
    if (rows.length === 0) return { accepted: 0, dropped };

    const { error: insertError } = await this.supabase.client
      .from('promotion_events')
      .insert(rows);

    if (insertError) throw new Error(`Failed to ingest promotion events: ${insertError.message}`);

    // Recompute the touched (campaign, today-in-Nairobi) cells. Idempotent —
    // failures here never lose data (raw events are already stored) and the
    // next batch for the same day repairs the rollup.
    const day = nairobiDayOf(new Date());
    for (const campaignId of new Set(rows.map((r) => r.campaign_id))) {
      const { error: rpcError } = await this.supabase.client.rpc(
        'fn_recompute_promotion_daily_stats',
        { p_campaign_id: campaignId, p_day: day },
      );
      if (rpcError) {
        this.logger.error(
          `[PROMO][ANALYTICS] rollup recompute failed for ${campaignId}/${day}: ${rpcError.message}`,
        );
      }
    }

    return { accepted: rows.length, dropped };
  }

  // ── Owner dashboard ─────────────────────────────────────────────────────────

  /**
   * Per-campaign dashboard: status, package, period, days remaining, totals
   * (impressions by placement, clicks, taps, messages, CTR) and the daily
   * trend. `requireOwner` is skipped for the admin surface.
   */
  async dashboard(
    campaignId: string,
    userId: string | null,
    opts: { requireOwner: boolean } = { requireOwner: true },
  ) {
    const { data: campaignData, error } = await this.supabase.client
      .from('promotion_campaigns')
      .select(
        'id, owner_user_id, status, post_id, post_title, package_id, package_name, ' +
          'price_kes, duration_days, starts_at, ends_at, created_at',
      )
      .eq('id', campaignId)
      .maybeSingle();

    if (error) throw new Error(`Failed to load campaign ${campaignId}: ${error.message}`);
    if (!campaignData) throw new NotFoundException(`Campaign ${campaignId} not found.`);
    const campaign = campaignData as unknown as {
      id: string;
      owner_user_id: string;
      status: string;
      post_id: string | null;
      post_title: string | null;
      package_id: string;
      package_name: string;
      price_kes: number;
      duration_days: number;
      starts_at: string | null;
      ends_at: string | null;
      created_at: string;
    };
    if (opts.requireOwner && campaign.owner_user_id !== userId) {
      throw new ForbiddenException('This campaign belongs to another account.');
    }

    const { data: statsData, error: statsError } = await this.supabase.client
      .from('promotion_daily_stats')
      .select(
        'campaign_id, day, impressions_discover, impressions_search, impressions_category, ' +
          'impressions_nearby, clicks, profile_views, phone_taps, whatsapp_taps, messages, bookings',
      )
      .eq('campaign_id', campaignId)
      .order('day', { ascending: true })
      .limit(120);

    if (statsError) throw new Error(`Failed to load campaign stats: ${statsError.message}`);
    const days = (statsData ?? []) as unknown as DailyStatsRow[];

    const totals = {
      impressions: 0,
      impressions_discover: 0,
      impressions_search: 0,
      impressions_category: 0,
      impressions_nearby: 0,
      clicks: 0,
      profile_views: 0,
      phone_taps: 0,
      whatsapp_taps: 0,
      messages: 0,
      bookings: 0,
      ctr: 0,
    };

    const daily = days.map((d) => {
      const impressions =
        d.impressions_discover + d.impressions_search + d.impressions_category + d.impressions_nearby;
      totals.impressions += impressions;
      totals.impressions_discover += d.impressions_discover;
      totals.impressions_search += d.impressions_search;
      totals.impressions_category += d.impressions_category;
      totals.impressions_nearby += d.impressions_nearby;
      totals.clicks += d.clicks;
      totals.profile_views += d.profile_views;
      totals.phone_taps += d.phone_taps;
      totals.whatsapp_taps += d.whatsapp_taps;
      totals.messages += d.messages;
      totals.bookings += d.bookings;
      return {
        day: d.day,
        impressions,
        clicks: d.clicks,
        profile_views: d.profile_views,
        phone_taps: d.phone_taps,
        whatsapp_taps: d.whatsapp_taps,
        messages: d.messages,
        bookings: d.bookings,
      };
    });

    totals.ctr = totals.impressions > 0 ? totals.clicks / totals.impressions : 0;

    return {
      campaign: {
        id: campaign.id,
        status: campaign.status,
        post_id: campaign.post_id,
        post_title: campaign.post_title,
        package_id: campaign.package_id,
        package_name: campaign.package_name,
        price_kes: campaign.price_kes,
        duration_days: campaign.duration_days,
        starts_at: campaign.starts_at,
        ends_at: campaign.ends_at,
        created_at: campaign.created_at,
        days_remaining: daysRemaining(
          campaign.ends_at ? new Date(campaign.ends_at) : null,
          new Date(),
        ),
      },
      totals,
      daily,
    };
  }
}
