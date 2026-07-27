import { Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { DEFAULT_FEED_CONFIG } from './ranking/defaults';
import { FeedConfig } from './ranking/types';

/**
 * Ranking configuration: `feed_settings` merged OVER the compiled defaults.
 *
 * Deliberately the same service shape as `PromotionSettingsService`, because
 * the same property is being bought: a ranking engine is tuned continuously,
 * and every tuning cycle that needs a deploy is a tuning cycle that does not
 * happen.
 *
 * Three layers of safety, in order of how likely each is to matter:
 *   1. a failed query keeps the last good cache, or the defaults;
 *   2. a missing key keeps that whole section's defaults;
 *   3. a key present with the wrong TYPE is ignored, key by key — so one
 *      fat-fingered value in the SQL editor degrades exactly one number
 *      instead of taking Discover down.
 *
 * Cached 60 s: this sits on the feed hot path, and a minute is well inside the
 * feedback loop of anyone actually tuning weights.
 */

const CACHE_TTL_MS = 60_000;

@Injectable()
export class FeedSettingsService {
  private readonly logger = new Logger(FeedSettingsService.name);
  private cache: { config: FeedConfig; expiresAt: number } | null = null;

  constructor(private readonly supabase: SupabaseService) {}

  async config(): Promise<FeedConfig> {
    const now = Date.now();
    if (this.cache && now < this.cache.expiresAt) return this.cache.config;

    const { data, error } = await this.supabase.client.from('feed_settings').select('key, value');

    if (error) {
      // Migration 090 not applied yet, or a transient outage. Either way the
      // feed keeps ranking on compiled defaults — it never fails to rank.
      this.logger.warn(`[FEED][SETTINGS] load failed — using defaults: ${error.message}`);
      const config = this.cache?.config ?? DEFAULT_FEED_CONFIG;
      this.cache = { config, expiresAt: now + CACHE_TTL_MS };
      return config;
    }

    const rows: Record<string, Record<string, unknown>> = {};
    for (const row of data ?? []) {
      const key = (row as { key: string }).key;
      const value = (row as { value: unknown }).value;
      if (key && value && typeof value === 'object') {
        rows[key] = value as Record<string, unknown>;
      }
    }

    const config = this.build(rows);
    this.cache = { config, expiresAt: now + CACHE_TTL_MS };
    return config;
  }

  /** Drop the cache so the next read refetches (admin edits, tests). */
  invalidate(): void {
    this.cache = null;
  }

  // ── merge helpers ──────────────────────────────────────────────────────────

  /**
   * Shallow merge with a per-key type guard. A stored value only wins when it
   * has the same JavaScript type as the default it replaces; anything else is
   * dropped with a warning and the default stands.
   */
  private merge<T extends object>(defaults: T, stored?: Record<string, unknown>): T {
    if (!stored) return { ...defaults };
    const out: Record<string, unknown> = { ...(defaults as Record<string, unknown>) };
    for (const [key, value] of Object.entries(stored)) {
      if (!(key in out)) continue;
      const expected = out[key];
      if (Array.isArray(expected) !== Array.isArray(value)) continue;
      if (!Array.isArray(expected) && typeof expected !== typeof value) continue;
      if (typeof value === 'number' && !Number.isFinite(value)) continue;
      out[key] = value;
    }
    return out as T;
  }

  /**
   * Numeric maps (weights, tier scores, event weights) merge per entry rather
   * than wholesale, so adding one override in SQL does not require restating
   * every other key.
   */
  private mergeNumberMap(
    defaults: Record<string, number>,
    stored: unknown,
  ): Record<string, number> {
    const out = { ...defaults };
    if (!stored || typeof stored !== 'object' || Array.isArray(stored)) return out;
    for (const [key, value] of Object.entries(stored as Record<string, unknown>)) {
      if (typeof value === 'number' && Number.isFinite(value)) out[key] = value;
    }
    return out;
  }

  private build(rows: Record<string, Record<string, unknown>>): FeedConfig {
    const d = DEFAULT_FEED_CONFIG;

    const behaviour = this.merge(d.behaviour, rows['behaviour']);
    behaviour.eventWeights = this.mergeNumberMap(
      d.behaviour.eventWeights,
      rows['behaviour']?.['eventWeights'],
    );

    const trust = this.merge(d.trust, rows['trust']);
    trust.tierScores = this.mergeNumberMap(d.trust.tierScores, rows['trust']?.['tierScores']);

    return {
      // Weights are a pure number map — merged entry-by-entry, never replaced.
      weights: this.mergeNumberMap(d.weights, rows['weights']) as FeedConfig['weights'],
      distance: this.merge(d.distance, rows['distance']),
      urgency: this.mergeUrgency(rows['urgency']),
      freshness: this.merge(d.freshness, rows['freshness']),
      staleness: this.merge(d.staleness, rows['staleness']),
      engagement: this.merge(d.engagement, rows['engagement']),
      behaviour,
      availability: this.merge(d.availability, rows['availability']),
      reliability: this.merge(d.reliability, rows['reliability']),
      trust,
      timeOfDay: this.mergeTimeOfDay(rows['time_of_day']),
      diversity: this.merge(d.diversity, rows['diversity']),
      retrieval: this.merge(d.retrieval, rows['retrieval']),
    };
  }

  /** Urgency carries an anchor array; validate its shape before trusting it. */
  private mergeUrgency(stored?: Record<string, unknown>): FeedConfig['urgency'] {
    const d = DEFAULT_FEED_CONFIG.urgency;
    const halfLife = stored?.['enumHalfLifeHours'];
    const out: FeedConfig['urgency'] = {
      anchors: d.anchors,
      enumScores: this.mergeNumberMap(d.enumScores, stored?.['enumScores']),
      enumHalfLifeHours:
        typeof halfLife === 'number' && Number.isFinite(halfLife) && halfLife > 0
          ? halfLife
          : d.enumHalfLifeHours,
    };

    const anchors = stored?.['anchors'];
    if (Array.isArray(anchors) && anchors.length >= 2) {
      const valid = anchors.every(
        (a) =>
          Array.isArray(a) &&
          a.length === 2 &&
          typeof a[0] === 'number' &&
          typeof a[1] === 'number' &&
          Number.isFinite(a[0]) &&
          Number.isFinite(a[1]),
      );
      if (valid) out.anchors = anchors as [number, number][];
      else this.logger.warn('[FEED][SETTINGS] urgency.anchors malformed — keeping defaults');
    }

    return out;
  }

  /** Time-of-day carries window objects; same treatment. */
  private mergeTimeOfDay(stored?: Record<string, unknown>): FeedConfig['timeOfDay'] {
    const d = DEFAULT_FEED_CONFIG.timeOfDay;
    const baseline = stored?.['baseline'];
    const out: FeedConfig['timeOfDay'] = {
      baseline: typeof baseline === 'number' && Number.isFinite(baseline) ? baseline : d.baseline,
      windows: d.windows,
    };

    const windows = stored?.['windows'];
    if (Array.isArray(windows)) {
      const valid = windows.every(
        (w) =>
          w &&
          typeof w === 'object' &&
          Array.isArray((w as { hours?: unknown }).hours) &&
          (w as { hours: unknown[] }).hours.length === 2 &&
          Array.isArray((w as { categories?: unknown }).categories),
      );
      if (valid) out.windows = windows as FeedConfig['timeOfDay']['windows'];
      else this.logger.warn('[FEED][SETTINGS] time_of_day.windows malformed — keeping defaults');
    }

    return out;
  }
}
