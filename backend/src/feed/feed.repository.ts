import { Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { RankingCandidate } from './ranking/types';

/**
 * The only place the ranking engine touches the database.
 *
 * Two calls, two very different shapes, and the split is the performance story
 * of the whole design:
 *
 *   `fetchCandidates`  ~400 NARROW rows — scalars only, for scoring
 *   `hydrate`          ~20  FULL rows   — joined images/applications/author,
 *                                          only for what survived
 *
 * The app's existing feed query fetches 50 full rows including every
 * application and every applicant's user record (audit §3.8). This fetches
 * heavy rows for a page of 20 and never for the other 380.
 */

/** Row shape returned by `fn_feed_candidates` (migration 095). */
interface CandidateRow {
  post_id: string;
  author_user_id: string;
  type: string;
  category: string;
  status: string;
  urgency: string;
  difficulty: string | null;
  price: number;
  location: string;
  title: string;
  description: string;
  created_at: string;
  is_urgent: boolean;
  urgent_expires_at: string | null;
  latitude: number | null;
  longitude: number | null;
  distance_km: number | null;
  author_profession: string | null;
  author_is_verified: boolean;
  author_account_type: string;
  author_available_until: string | null;
  author_last_seen: string | null;
  bayesian_rating: number | null;
  completion_rate: number | null;
  dispute_rate: number | null;
  total_reviews: number | null;
  completed_jobs: number | null;
  tier: string | null;
  application_count: number;
  save_count: number;
  message_count: number;
  view_count: number;
  viewer_has_applied: boolean;
  is_own_post: boolean;
  pools: string;
}

export interface CandidateQuery {
  viewerId: string | null;
  latitude: number | null;
  longitude: number | null;
  radiusKm: number;
  types: string[] | null;
  categories: string[] | null;
  query: string | null;
  minPrice: number | null;
  maxPrice: number | null;
  urgency: string | null;
  difficulty: string | null;
  city: string | null;
  area: string | null;
  affinityCategories: string[] | null;
  poolLimit: number;
  maxCandidates: number;
}

/**
 * The exact select shape `PostService.fetchPosts` uses in the app.
 *
 * Byte-identical on purpose: the client parses a ranked row with the SAME
 * `PostModel.fromJson` it uses for a direct Supabase read, so switching to the
 * ranked feed cannot introduce a parsing difference, and the fallback path
 * produces objects indistinguishable from the ranked one.
 */
const FEED_ROW_SELECT =
  '*, users!author_user_id(name, email, profile_image, avatar_url, phone_number), ' +
  'post_images(image_url), ' +
  'applications(*, users!applicant_user_id(name, email, profile_image, avatar_url, profession))';

@Injectable()
export class FeedRepository {
  private readonly logger = new Logger(FeedRepository.name);

  constructor(private readonly supabase: SupabaseService) {}

  /** Retrieval: four signal-aware pools, bounded, narrow rows. */
  async fetchCandidates(query: CandidateQuery): Promise<RankingCandidate[]> {
    const { data, error } = await this.supabase.client.rpc('fn_feed_candidates', {
      p_viewer_id: query.viewerId,
      p_lat: query.latitude,
      p_lng: query.longitude,
      p_radius_km: query.radiusKm,
      p_types: query.types,
      p_categories: query.categories,
      p_query: query.query,
      p_min_price: query.minPrice,
      p_max_price: query.maxPrice,
      p_urgency: query.urgency,
      p_difficulty: query.difficulty,
      p_city: query.city,
      p_area: query.area,
      p_affinity_categories: query.affinityCategories,
      p_pool_limit: query.poolLimit,
      p_max_candidates: query.maxCandidates,
    });

    if (error) {
      // Thrown, not swallowed: the caller converts a retrieval failure into the
      // client's fallback path. Silently returning [] here would render an
      // empty feed and tell the user "no posts found", which is a lie.
      throw new Error(`fn_feed_candidates failed: ${error.message}`);
    }

    return ((data ?? []) as CandidateRow[]).map((row) => this.toCandidate(row));
  }

  /**
   * Hydration: full feed rows for the ranked page, returned in the ORDER GIVEN.
   * Postgres has no reason to honour the order of an `IN` list, so the ranking
   * is re-applied here — losing it would silently undo the entire engine.
   */
  async hydrate(postIds: string[]): Promise<Map<string, Record<string, unknown>>> {
    const byId = new Map<string, Record<string, unknown>>();
    if (postIds.length === 0) return byId;

    const { data, error } = await this.supabase.client
      .from('posts')
      .select(FEED_ROW_SELECT)
      .in('id', postIds);

    if (error) throw new Error(`feed hydration failed: ${error.message}`);

    for (const row of (data ?? []) as unknown as Record<string, unknown>[]) {
      const id = row['id'];
      if (typeof id === 'string') byId.set(id, row);
    }
    return byId;
  }

  // ── mapping ────────────────────────────────────────────────────────────────

  private toCandidate(row: CandidateRow): RankingCandidate {
    return {
      postId: row.post_id,
      authorUserId: row.author_user_id ?? '',
      type: row.type,
      category: row.category ?? '',
      status: row.status,
      urgency: row.urgency,
      difficulty: row.difficulty,
      price: this.num(row.price) ?? 0,
      location: row.location ?? '',
      title: row.title ?? '',
      description: row.description ?? '',
      createdAt: this.date(row.created_at) ?? new Date(0),
      isUrgent: row.is_urgent === true,
      urgentExpiresAt: this.date(row.urgent_expires_at),
      latitude: this.num(row.latitude),
      longitude: this.num(row.longitude),
      distanceKm: this.num(row.distance_km),
      authorProfession: row.author_profession,
      authorIsVerified: row.author_is_verified === true,
      authorAccountType: row.author_account_type ?? 'individual',
      authorAvailableUntil: this.date(row.author_available_until),
      authorLastSeen: this.date(row.author_last_seen),
      bayesianRating: this.num(row.bayesian_rating),
      completionRate: this.num(row.completion_rate),
      disputeRate: this.num(row.dispute_rate),
      totalReviews: this.num(row.total_reviews),
      completedJobs: this.num(row.completed_jobs),
      tier: row.tier,
      applicationCount: this.num(row.application_count) ?? 0,
      saveCount: this.num(row.save_count) ?? 0,
      messageCount: this.num(row.message_count) ?? 0,
      viewCount: this.num(row.view_count) ?? 0,
      viewerHasApplied: row.viewer_has_applied === true,
      isOwnPost: row.is_own_post === true,
      pools: row.pools ?? '',
    };
  }

  /** null for anything non-numeric — "no reputation row" must stay null, not 0. */
  private num(value: unknown): number | null {
    if (value === null || value === undefined) return null;
    const n = typeof value === 'number' ? value : Number(value);
    return Number.isFinite(n) ? n : null;
  }

  private date(value: string | null | undefined): Date | null {
    if (!value) return null;
    const d = new Date(value);
    return Number.isNaN(d.getTime()) ? null : d;
  }
}
