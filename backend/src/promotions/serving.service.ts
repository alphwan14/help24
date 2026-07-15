import { Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { PromotionSettingsService, ServingSettings } from './settings.service';
import {
  PromotionPlacement,
  ServingCandidate,
  applyRelevance,
  selectSlots,
} from './serving-logic';

/**
 * Placement engine — GET /promotions/slots.
 *
 * The app calls this NON-BLOCKING, in parallel with its organic Supabase feed
 * read: organic content never waits on promotions, and every failure here
 * degrades to an unsponsored feed (empty items), never an error. That is why
 * this service catches everything and only logs.
 *
 * Eligibility is correct-by-query: only status='active' campaigns inside
 * their [starts_at, ends_at] window whose subject post is still open and
 * unarchived are ever considered — an overdue lifecycle sweep can never cause
 * over-serving. Relevance / ranking / rotation / cap are pure functions in
 * serving-logic.ts.
 */

export interface SlotItem {
  campaign_id: string;
  placement: PromotionPlacement;
  distance_km: number | null;
  /** Full posts row — the client renders it exactly like an organic feed row. */
  post: Record<string, unknown>;
}

export interface SlotsResponse {
  placement: PromotionPlacement;
  items: SlotItem[];
  /** Feed-composition hints so the client needs no second settings call. */
  serving: {
    discover_first_after: number;
    discover_gap: number;
  };
}

/** Rotation reshuffles every 10 minutes — stable while a user pages a feed. */
const ROTATION_BUCKET_MS = 10 * 60 * 1000;

/** Upper bound on eligible campaigns pulled per request (safety valve). */
const CANDIDATE_FETCH_LIMIT = 200;

@Injectable()
export class ServingService {
  private readonly logger = new Logger(ServingService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly settings: PromotionSettingsService,
  ) {}

  private maxSlotsFor(placement: PromotionPlacement, serving: ServingSettings): number {
    switch (placement) {
      case 'discover': return serving.discover_max_slots;
      case 'search':   return serving.search_max_slots;
      case 'category': return serving.category_max_slots;
      case 'nearby':   return serving.nearby_max_slots;
    }
  }

  async getSlots(params: {
    placement: PromotionPlacement;
    category?: string;
    q?: string;
    lat?: number;
    lng?: number;
    limit?: number;
  }): Promise<SlotsResponse> {
    const serving = await this.settings.serving();
    const empty: SlotsResponse = {
      placement: params.placement,
      items: [],
      serving: {
        discover_first_after: serving.discover_first_after,
        discover_gap: serving.discover_gap,
      },
    };

    try {
      const configuredCap = this.maxSlotsFor(params.placement, serving);
      const maxSlots = Math.max(
        0,
        Math.min(configuredCap, params.limit ?? configuredCap),
      );
      if (maxSlots === 0) return empty;

      const nowIso = new Date().toISOString();
      const { data, error } = await this.supabase.client
        .from('promotion_campaigns')
        // The embedded post mirrors PostService.fetchPosts so the client can
        // parse a slot with the same PostModel.fromJson as an organic row.
        .select(
          'id, owner_user_id, posts!inner(*, ' +
            'users!author_user_id(name, email, profile_image, avatar_url, phone_number), ' +
            'post_images(image_url))',
        )
        .eq('status', 'active')
        .not('post_id', 'is', null)
        .lte('starts_at', nowIso)
        .gte('ends_at', nowIso)
        .contains('placements', JSON.stringify([params.placement]))
        .eq('posts.status', 'open')
        .is('posts.archived_at', null)
        .limit(CANDIDATE_FETCH_LIMIT);

      if (error) {
        this.logger.error(`[PROMO][SERVE] eligibility query failed: ${error.message}`);
        return empty;
      }

      const rows = (data ?? []) as unknown as Array<{
        id: string;
        owner_user_id: string;
        posts: Record<string, unknown>;
      }>;
      if (rows.length === 0) return empty;

      // Quality signals for ranking (missing reputation → neutral zeros).
      const ownerIds = [...new Set(rows.map((r) => r.owner_user_id))];
      const { data: repData, error: repError } = await this.supabase.client
        .from('provider_reputation')
        .select('provider_id, bayesian_rating, completion_rate')
        .in('provider_id', ownerIds);

      if (repError) {
        this.logger.warn(`[PROMO][SERVE] reputation fetch failed (ranking degrades): ${repError.message}`);
      }
      const reputation = new Map(
        ((repData ?? []) as Array<{ provider_id: string; bayesian_rating: number; completion_rate: number }>).map(
          (r) => [r.provider_id, r],
        ),
      );

      const relevanceCtx = {
        placement: params.placement,
        category: params.category ?? null,
        query: params.q ?? null,
        lat: params.lat ?? null,
        lng: params.lng ?? null,
        nearbyMaxRadiusKm: serving.nearby_max_radius_km,
      };

      const candidates: ServingCandidate[] = [];
      for (const row of rows) {
        const rep = reputation.get(row.owner_user_id);
        const candidate = applyRelevance(
          {
            campaignId: row.id,
            ownerUserId: row.owner_user_id,
            post: row.posts as ServingCandidate['post'],
            bayesianRating: rep?.bayesian_rating ?? 0,
            completionRate: rep?.completion_rate ?? 0,
          },
          relevanceCtx,
        );
        if (candidate) candidates.push(candidate);
      }

      const selected = selectSlots(candidates, {
        maxSlots,
        nearbyMaxRadiusKm: serving.nearby_max_radius_km,
        bucket: Math.floor(Date.now() / ROTATION_BUCKET_MS),
      });

      return {
        ...empty,
        items: selected.map((c) => ({
          campaign_id: c.campaignId,
          placement: params.placement,
          distance_km: c.distanceKm ?? null,
          post: c.post,
        })),
      };
    } catch (err) {
      // The feed must never break because promotions did.
      this.logger.error(
        `[PROMO][SERVE] unexpected failure — serving empty: ${err instanceof Error ? err.message : err}`,
      );
      return empty;
    }
  }
}
