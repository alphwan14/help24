import { Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { FeedConfig, RecentSearch, ViewerContext, ViewerProfession } from './ranking/types';

/**
 * Builds the `ViewerContext` — everything the engine knows about who is asking.
 *
 * Two caches, because the two halves of the profile change at very different
 * rates:
 *
 *   * the PROFESSION REGISTRY (professions → categories, group membership,
 *     aliases) is identical for every user and changes when someone edits a
 *     catalogue row — cached process-wide for 10 minutes;
 *   * a USER's own profile + affinity changes as they act — cached per user
 *     for 5 minutes, which is short enough that saving a post visibly affects
 *     the next pull-to-refresh but long enough that scrolling does not hammer
 *     the database.
 *
 * Every lookup here degrades to "no data" rather than to an error. A viewer
 * whose profile cannot be read gets an unpersonalised feed, not a failed one.
 */

const REGISTRY_TTL_MS = 10 * 60_000;
const VIEWER_TTL_MS = 5 * 60_000;
/** Hard bound on the per-user cache so a traffic spike cannot grow it forever. */
const VIEWER_CACHE_MAX = 5_000;

interface ProfessionRow {
  id: string;
  name: string;
  group_id: string | null;
  category_id: string | null;
  aliases: string[] | null;
}

interface ProfessionRegistry {
  /** professions.id → row. */
  byId: Map<string, ProfessionRow>;
  /** categories.id → categories.name (what `posts.category` actually stores). */
  categoryNameById: Map<string, string>;
  /** professions.group_id → lowercased category names reachable from the group. */
  groupCategoryNames: Map<string, Set<string>>;
}

interface CachedViewer {
  // `medianKnownDistanceKm` is deliberately excluded: it is a property of the
  // retrieved candidate SET, computed per request by FeedService, and caching
  // it against a user would carry one request's corpus into the next.
  profile: Omit<
    ViewerContext,
    'latitude' | 'longitude' | 'localHour' | 'now' | 'medianKnownDistanceKm'
  >;
  expiresAt: number;
}

@Injectable()
export class ViewerContextService {
  private readonly logger = new Logger(ViewerContextService.name);
  private registry: { value: ProfessionRegistry; expiresAt: number } | null = null;
  private readonly viewerCache = new Map<string, CachedViewer>();

  constructor(private readonly supabase: SupabaseService) {}

  /** Drop all caches (admin edits, tests). */
  invalidate(userId?: string): void {
    if (userId) this.viewerCache.delete(userId);
    else {
      this.viewerCache.clear();
      this.registry = null;
    }
  }

  // ── Profession registry (shared by every viewer) ───────────────────────────

  private async loadRegistry(): Promise<ProfessionRegistry> {
    const now = Date.now();
    if (this.registry && now < this.registry.expiresAt) return this.registry.value;

    const empty: ProfessionRegistry = {
      byId: new Map(),
      categoryNameById: new Map(),
      groupCategoryNames: new Map(),
    };

    try {
      const [professions, categories] = await Promise.all([
        this.supabase.client.from('professions').select('id, name, group_id, category_id, aliases'),
        this.supabase.client.from('categories').select('id, name'),
      ]);

      if (professions.error || categories.error) {
        this.logger.warn(
          `[FEED][VIEWER] registry load failed — profession matching disabled: ` +
            `${professions.error?.message ?? categories.error?.message}`,
        );
        // Cache the empty registry briefly so a hard outage does not turn every
        // feed request into two more failing queries.
        this.registry = { value: this.registry?.value ?? empty, expiresAt: now + 30_000 };
        return this.registry.value;
      }

      const value: ProfessionRegistry = {
        byId: new Map(),
        categoryNameById: new Map(),
        groupCategoryNames: new Map(),
      };

      for (const row of (categories.data ?? []) as { id: string; name: string }[]) {
        value.categoryNameById.set(row.id, row.name);
      }

      for (const row of (professions.data ?? []) as ProfessionRow[]) {
        value.byId.set(row.id, row);

        const categoryName = row.category_id
          ? value.categoryNameById.get(row.category_id)
          : undefined;
        if (row.group_id && categoryName) {
          const set = value.groupCategoryNames.get(row.group_id) ?? new Set<string>();
          set.add(categoryName.trim().toLowerCase());
          value.groupCategoryNames.set(row.group_id, set);
        }
      }

      this.registry = { value, expiresAt: now + REGISTRY_TTL_MS };
      return value;
    } catch (err) {
      this.logger.warn(`[FEED][VIEWER] registry load threw: ${this.msg(err)}`);
      return this.registry?.value ?? empty;
    }
  }

  /** Turn a `professions.id` into the matcher input the signals expect. */
  private toViewerProfession(
    professionId: string,
    registry: ProfessionRegistry,
    weight: number,
    isPrimary: boolean,
  ): ViewerProfession | null {
    const row = registry.byId.get(professionId);
    if (!row) {
      // Legacy free-text profession (pre-086 users still hold prose here).
      // It cannot map to a category, but its own words are still usable as
      // text-match tokens — better than dropping the user's only trade signal.
      const token = professionId.trim().toLowerCase();
      if (token.length < 3) return null;
      return { id: professionId, groupId: null, categoryNames: [], tokens: [token], weight, isPrimary };
    }

    const categoryName = row.category_id ? registry.categoryNameById.get(row.category_id) : undefined;

    const tokens = [row.name, ...(row.aliases ?? [])]
      .filter((t): t is string => typeof t === 'string' && t.trim().length >= 3)
      .map((t) => t.trim().toLowerCase());

    return {
      id: row.id,
      groupId: row.group_id,
      categoryNames: categoryName ? [categoryName] : [],
      tokens: [...new Set(tokens)],
      weight,
      isPrimary,
    };
  }

  // ── Per-viewer profile + affinity ──────────────────────────────────────────

  private async loadViewerProfile(
    userId: string,
    config: FeedConfig,
  ): Promise<CachedViewer['profile']> {
    const registry = await this.loadRegistry();

    const emptyProfile: CachedViewer['profile'] = {
      userId,
      professions: [],
      groupCategoryNames: registry.groupCategoryNames,
      categoryAffinity: new Map(),
      professionAffinity: new Map(),
      authorAffinity: new Map(),
      recentSearches: [],
    };

    try {
      const [user, skills, affinity] = await Promise.all([
        this.supabase.client.from('users').select('profession').eq('id', userId).maybeSingle(),
        this.supabase.client.from('user_skills').select('profession_id, weight').eq('user_id', userId),
        this.supabase.client.rpc('fn_user_affinity', {
          p_user_id: userId,
          p_halflife_days: config.behaviour.halfLifeDays,
          p_lookback_days: config.behaviour.lookbackDays,
          p_limit: config.behaviour.maxKeys,
          p_event_weights: config.behaviour.eventWeights,
          p_search_lookback_days: config.behaviour.searchLookbackDays,
          p_search_halflife_hours: config.behaviour.searchHalfLifeHours,
        }),
      ]);

      const professions: ViewerProfession[] = [];

      const primaryId = (user.data as { profession?: string } | null)?.profession?.trim();
      if (primaryId) {
        const primary = this.toViewerProfession(primaryId, registry, 1, true);
        if (primary) professions.push(primary);
      }

      if (skills.error) {
        // Migration 093 not applied yet — the skills signal simply stays "not
        // applicable", which is exactly its shipped-empty behaviour anyway.
        this.logger.debug?.(`[FEED][VIEWER] user_skills unavailable: ${skills.error.message}`);
      } else {
        for (const row of (skills.data ?? []) as { profession_id: string; weight: number }[]) {
          if (!row.profession_id || row.profession_id === primaryId) continue;
          const secondary = this.toViewerProfession(
            row.profession_id,
            registry,
            typeof row.weight === 'number' ? row.weight : 0.7,
            false,
          );
          if (secondary) professions.push(secondary);
        }
      }

      const categoryAffinity = new Map<string, number>();
      const professionAffinity = new Map<string, number>();
      const authorAffinity = new Map<string, number>();
      const recentSearches: RecentSearch[] = [];

      if (affinity.error) {
        this.logger.debug?.(`[FEED][VIEWER] affinity unavailable: ${affinity.error.message}`);
      } else {
        const rows = (affinity.data ?? []) as {
          dimension: string;
          key: string;
          weight: number;
        }[];
        for (const row of rows) {
          if (!row?.key) continue;
          const weight = typeof row.weight === 'number' && Number.isFinite(row.weight) ? row.weight : 0;
          switch (row.dimension) {
            case 'category':
              categoryAffinity.set(row.key, weight);
              break;
            case 'profession':
              professionAffinity.set(row.key, weight);
              break;
            case 'author':
              authorAffinity.set(row.key, weight);
              break;
            case 'search':
              recentSearches.push({ query: row.key, recency: weight });
              break;
          }
        }
        recentSearches.sort((a, b) => b.recency - a.recency);
      }

      return {
        userId,
        professions,
        groupCategoryNames: registry.groupCategoryNames,
        categoryAffinity,
        professionAffinity,
        authorAffinity,
        recentSearches,
      };
    } catch (err) {
      this.logger.warn(`[FEED][VIEWER] profile load failed — unpersonalised feed: ${this.msg(err)}`);
      return emptyProfile;
    }
  }

  // ── Public entry point ─────────────────────────────────────────────────────

  /**
   * Assemble the context for one request.
   *
   * Location and local hour are per-REQUEST (the user moves, and the clock
   * runs) so they are never cached; the profile half is.
   */
  async build(
    params: {
      userId?: string | null;
      latitude?: number | null;
      longitude?: number | null;
      /** Minutes the viewer's local time is ahead of UTC (e.g. Nairobi = 180). */
      timezoneOffsetMinutes?: number | null;
    },
    config: FeedConfig,
    now: Date = new Date(),
  ): Promise<ViewerContext> {
    const userId = params.userId?.trim() || null;
    const registry = await this.loadRegistry();

    let profile: CachedViewer['profile'] = {
      userId,
      professions: [],
      groupCategoryNames: registry.groupCategoryNames,
      categoryAffinity: new Map(),
      professionAffinity: new Map(),
      authorAffinity: new Map(),
      recentSearches: [],
    };

    if (userId) {
      const cached = this.viewerCache.get(userId);
      if (cached && Date.now() < cached.expiresAt) {
        profile = cached.profile;
      } else {
        profile = await this.loadViewerProfile(userId, config);
        this.rememberViewer(userId, profile);
      }
    }

    return {
      ...profile,
      latitude: this.finiteOrNull(params.latitude),
      longitude: this.finiteOrNull(params.longitude),
      localHour: this.localHour(now, params.timezoneOffsetMinutes),
      // Filled by FeedService once the candidate set exists — it is a property
      // of the retrieved set, not of the viewer's profile.
      medianKnownDistanceKm: null,
      now,
    };
  }

  /** LRU-ish: evict the oldest entry once the cache is full. */
  private rememberViewer(userId: string, profile: CachedViewer['profile']): void {
    if (this.viewerCache.size >= VIEWER_CACHE_MAX) {
      const oldest = this.viewerCache.keys().next();
      if (!oldest.done) this.viewerCache.delete(oldest.value);
    }
    this.viewerCache.set(userId, { profile, expiresAt: Date.now() + VIEWER_TTL_MS });
  }

  /**
   * The viewer's local hour. The client sends its UTC offset because the
   * server's timezone is an accident of hosting: a Nairobi user browsing at
   * 07:00 must not be ranked as though it were 04:00.
   */
  private localHour(now: Date, offsetMinutes?: number | null): number {
    const offset =
      typeof offsetMinutes === 'number' && Number.isFinite(offsetMinutes)
        ? Math.max(-14 * 60, Math.min(14 * 60, offsetMinutes))
        : 0;
    const shifted = new Date(now.getTime() + offset * 60_000);
    return shifted.getUTCHours();
  }

  private finiteOrNull(value: number | null | undefined): number | null {
    return typeof value === 'number' && Number.isFinite(value) ? value : null;
  }

  private msg(err: unknown): string {
    return err instanceof Error ? err.message : String(err);
  }
}
