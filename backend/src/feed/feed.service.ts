import { Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { FeedSettingsService } from './feed-settings.service';
import { ViewerContextService } from './viewer-context.service';
import { FeedRepository } from './feed.repository';
import { scoreCandidates, maxPossibleScore } from './ranking/scorer';
import { diversify } from './ranking/diversity';
import { FeedConfig, ScoredCandidate, ViewerContext } from './ranking/types';
import { FeedQueryDto, IngestInteractionsDto, SetAvailabilityDto } from './dto/feed.dto';

/**
 * The Discover recommendation engine's orchestration layer.
 *
 * Retrieval → scoring → composition → hydration. Every decision that could be
 * a pure function IS one, in `ranking/`; this file only sequences them and
 * talks to the database.
 */

export interface FeedItem {
  post: Record<string, unknown>;
  score: number;
  signals: {
    key: string;
    label: string;
    weight: number;
    raw: number;
    points: number;
    detail?: Record<string, unknown>;
  }[];
  /** Present only with `?explain=1`. */
  debug?: {
    skipped: string[];
    pools: string;
    diversity?: { movedFrom: number; reason: string };
    maxPossibleScore: number;
  };
}

export interface FeedResponse {
  items: FeedItem[];
  page: number;
  page_size: number;
  /** Whether another page exists in the scored candidate set. */
  has_more: boolean;
  /** Candidates considered before paging — the ranker's field of view. */
  candidate_count: number;
  /** Milliseconds spent in retrieval + scoring + hydration. */
  took_ms: number;
  personalised: boolean;
}

@Injectable()
export class FeedService {
  private readonly logger = new Logger(FeedService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly settings: FeedSettingsService,
    private readonly viewerContext: ViewerContextService,
    private readonly repository: FeedRepository,
  ) {}

  // ── GET /feed ──────────────────────────────────────────────────────────────

  async getFeed(query: FeedQueryDto): Promise<FeedResponse> {
    const startedAt = Date.now();
    const config = await this.settings.config();
    const explain = query.explain === '1' || query.explain === 'true';

    const viewer = await this.viewerContext.build(
      {
        userId: query.user_id,
        latitude: query.lat,
        longitude: query.lng,
        timezoneOffsetMinutes: query.tz_offset,
      },
      config,
    );

    const pageSize = Math.min(
      query.page_size ?? config.retrieval.pageSize,
      config.retrieval.maxPageSize,
    );
    const page = Math.max(query.page ?? 0, 0);
    const startIndex = page * pageSize;

    const candidates = await this.repository.fetchCandidates({
      viewerId: viewer.userId,
      latitude: viewer.latitude,
      longitude: viewer.longitude,
      radiusKm: query.radius_km ?? config.retrieval.radiusKm,
      types: this.typesForScope(query.scope),
      categories: this.parseCategories(query.categories),
      query: query.q?.trim() || null,
      minPrice: query.min_price ?? null,
      maxPrice: query.max_price ?? null,
      urgency: query.urgency ?? null,
      difficulty: query.difficulty ?? null,
      city: query.city?.trim() || null,
      area: query.area?.trim() || null,
      affinityCategories: this.affinityCategories(viewer, config),
      poolLimit: config.retrieval.poolLimit,
      maxCandidates: config.retrieval.maxCandidates,
    });

    if (candidates.length === 0) {
      return {
        items: [],
        page,
        page_size: pageSize,
        has_more: false,
        candidate_count: 0,
        took_ms: Date.now() - startedAt,
        personalised: this.isPersonalised(viewer),
      };
    }

    const scored = scoreCandidates(candidates, viewer, config, { explain });

    // Diversity runs over the WHOLE scored list and then slices, so page 2
    // inherits page 1's composition history instead of restarting the same
    // pattern (three plumbers at the top of every page).
    const pageItems = diversify(scored, config.diversity, pageSize, startIndex);

    const hydrated = await this.repository.hydrate(pageItems.map((i) => i.candidate.postId));

    const items = pageItems
      .map((item) => this.toFeedItem(item, hydrated, config, explain))
      .filter((item): item is FeedItem => item !== null);

    return {
      items,
      page,
      page_size: pageSize,
      has_more: scored.length > startIndex + pageItems.length,
      candidate_count: scored.length,
      took_ms: Date.now() - startedAt,
      personalised: this.isPersonalised(viewer),
    };
  }

  /**
   * Turn a scored candidate into a response row.
   *
   * Returns null when hydration produced nothing for the id — a post archived
   * or closed in the milliseconds between retrieval and hydration. Dropping it
   * is correct: showing a card the user cannot act on is worse than a page of
   * nineteen.
   */
  private toFeedItem(
    item: ScoredCandidate,
    hydrated: Map<string, Record<string, unknown>>,
    config: FeedConfig,
    explain: boolean,
  ): FeedItem | null {
    const post = hydrated.get(item.candidate.postId);
    if (!post) return null;

    const feedItem: FeedItem = {
      post,
      score: item.score,
      signals: item.contributions,
    };

    if (explain) {
      feedItem.debug = {
        skipped: item.skipped,
        pools: item.candidate.pools,
        diversity: item.diversity,
        maxPossibleScore: maxPossibleScore(config),
      };
    }

    return feedItem;
  }

  // ── POST /feed/interactions ────────────────────────────────────────────────

  /**
   * Ingest behavioural events. Never throws: the caller answers 202 regardless,
   * because a user browsing a feed must never see an error caused by analytics
   * they did not ask for.
   */
  async ingestInteractions(dto: IngestInteractionsDto): Promise<{ accepted: number }> {
    const userId = dto.user_id?.trim();
    if (!userId || !Array.isArray(dto.events) || dto.events.length === 0) {
      return { accepted: 0 };
    }

    const rows = dto.events
      .filter((e) => e && typeof e.kind === 'string')
      .map((e) => ({
        user_id: userId,
        kind: e.kind,
        post_id: e.post_id?.trim() || null,
        author_id: e.author_id?.trim() || null,
        category: e.category?.trim() || null,
        profession: e.profession?.trim() || null,
        query: e.kind === 'search' ? e.query?.trim()?.slice(0, 200) || null : null,
      }));

    if (rows.length === 0) return { accepted: 0 };

    try {
      const { error } = await this.supabase.client.from('user_interactions').insert(rows);
      if (error) {
        this.logger.warn(`[FEED][INTERACTIONS] insert failed: ${error.message}`);
        return { accepted: 0 };
      }
      // The next feed request should reflect what the user just did.
      this.viewerContext.invalidate(userId);
      return { accepted: rows.length };
    } catch (err) {
      this.logger.warn(`[FEED][INTERACTIONS] insert threw: ${this.msg(err)}`);
      return { accepted: 0 };
    }
  }

  // ── POST /feed/availability ────────────────────────────────────────────────

  /**
   * Set or clear the provider's "available now" window (signal 7).
   *
   * Capped at 24 h and stored as an expiry instant, so availability someone
   * forgot to turn off stops lying by itself — see migration 093.
   */
  async setAvailability(dto: SetAvailabilityDto): Promise<{ available_until: string | null }> {
    const userId = dto.user_id.trim();
    const hours = Math.min(Math.max(dto.hours ?? 8, 1), 24);
    const availableUntil = dto.available
      ? new Date(Date.now() + hours * 3_600_000).toISOString()
      : null;

    const { error } = await this.supabase.client
      .from('users')
      .update({ available_until: availableUntil })
      .eq('id', userId);

    if (error) throw new Error(`Failed to update availability: ${error.message}`);

    this.viewerContext.invalidate(userId);
    return { available_until: availableUntil };
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  /**
   * Scope → the `posts.type` values it admits.
   *
   * `all` deliberately excludes `job`, matching what Discover shows today (the
   * Jobs tab is its own surface). `null` would have silently added job posts to
   * everyone's Discover feed — a product change disguised as a refactor.
   */
  private typesForScope(scope?: string): string[] | null {
    switch (scope) {
      case 'requests':
        return ['request'];
      case 'offers':
        return ['offer'];
      case 'jobs':
        return ['job'];
      case 'all':
      default:
        return ['request', 'offer'];
    }
  }

  private parseCategories(raw?: string): string[] | null {
    if (!raw) return null;
    const list = raw
      .split(',')
      .map((c) => c.trim())
      .filter(Boolean)
      .slice(0, 40);
    return list.length > 0 ? list : null;
  }

  /**
   * Retrieval hint for the `affinity` pool: the categories this viewer works in
   * or keeps opening. A HINT, not a filter — the pool only decides what gets
   * *considered*; the user's explicit category filter is applied separately and
   * is absolute.
   */
  private affinityCategories(viewer: ViewerContext, config: FeedConfig): string[] | null {
    const names = new Set<string>();

    for (const profession of viewer.professions) {
      for (const name of profession.categoryNames) names.add(name);
    }

    // Only categories with real behavioural pull — a single stray impression
    // should not widen retrieval.
    for (const [category, weight] of viewer.categoryAffinity) {
      if (weight >= 0.2) names.add(category);
    }

    if (names.size === 0) return null;
    return [...names].slice(0, Math.max(config.behaviour.maxKeys, 10));
  }

  private isPersonalised(viewer: ViewerContext): boolean {
    return (
      viewer.userId !== null &&
      (viewer.professions.length > 0 ||
        viewer.categoryAffinity.size > 0 ||
        viewer.recentSearches.length > 0)
    );
  }

  private msg(err: unknown): string {
    return err instanceof Error ? err.message : String(err);
  }
}
