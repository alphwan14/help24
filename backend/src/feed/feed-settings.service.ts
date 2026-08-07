import { BadRequestException, ConflictException, Injectable, Logger } from '@nestjs/common';
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

/**
 * The `feed_settings` rows this service reads, and therefore the only keys the
 * admin surface will write. The list is the contract: a typo becomes a 400 at
 * the edge instead of a row that `build()` silently ignores — which is exactly
 * how a "why did my tuning do nothing?" afternoon starts.
 *
 * Note `time_of_day`: the table is snake_case while `FeedConfig` is camelCase,
 * so the mapping is deliberate and lives in `build()`.
 */
export const FEED_SETTINGS_KEYS = [
  'weights',
  'distance',
  'urgency',
  'freshness',
  'staleness',
  'engagement',
  'behaviour',
  'availability',
  'reliability',
  'trust',
  'time_of_day',
  'diversity',
  'retrieval',
] as const;

export type FeedSettingsKey = (typeof FEED_SETTINGS_KEYS)[number];

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

  isSettingsKey(key: string): key is FeedSettingsKey {
    return (FEED_SETTINGS_KEYS as readonly string[]).includes(key);
  }

  /**
   * The raw stored overrides, unmerged. The admin surface shows these beside
   * the effective config so it is obvious which numbers are actually pinned in
   * the table and which are just the compiled default showing through — a
   * distinction the merged document cannot express.
   */
  async storedOverrides(): Promise<Record<string, Record<string, unknown>>> {
    const { data, error } = await this.supabase.client
      .from('feed_settings')
      .select('key, value');

    if (error) throw new Error(`Failed to read feed settings: ${error.message}`);

    const rows: Record<string, Record<string, unknown>> = {};
    for (const row of data ?? []) {
      const key = (row as { key: string }).key;
      const value = (row as { value: unknown }).value;
      if (key && value && typeof value === 'object' && !Array.isArray(value)) {
        rows[key] = value as Record<string, unknown>;
      }
    }
    return rows;
  }

  /**
   * The compiled default document a stored key merges over. Exists so the
   * admin surface can reject a field the reader would silently ignore.
   *
   * `time_of_day` is the one key whose table name differs from its config
   * field (`timeOfDay`); everything else is a straight lookup.
   */
  defaultDocumentFor(key: FeedSettingsKey): Record<string, unknown> {
    const d = DEFAULT_FEED_CONFIG as unknown as Record<string, unknown>;
    const field = key === 'time_of_day' ? 'timeOfDay' : key;
    return d[field] as Record<string, unknown>;
  }

  /**
   * Admin: MERGE fields into one settings document.
   *
   * WHY THIS MERGES INSTEAD OF REPLACING
   * ------------------------------------
   * Every document in production is a FULL document — `weights` carries all
   * fifteen entries. A replacing write of `{ distance: 35 }` would therefore
   * store a one-field document and silently drop the other fourteen, which the
   * reader would then fill from compiled defaults. Today that is invisible
   * because the seeded values equal the defaults; the first time anyone pins a
   * non-default weight, the next partial write would quietly discard it.
   *
   * So a PATCH does what PATCH says: the submitted fields win, everything
   * already stored survives.
   *
   * WHY THE WRITE IS GUARDED
   * ------------------------
   * Merging requires read-modify-write, which is a lost-update waiting to
   * happen: two admins tuning different weights in the same minute would see
   * one edit vanish. The write therefore asserts the `updated_at` it read, the
   * same optimistic-concurrency pattern `lockEscrowForPayment` and
   * `campaigns.service.ts` use. A racing write makes the guard match nothing
   * and the caller gets a 409 instead of a silent loss.
   */
  async adminUpdate(key: FeedSettingsKey, patch: Record<string, unknown>): Promise<void> {
    const unknownFields = Object.keys(patch).filter(
      (field) => !(field in this.defaultDocumentFor(key)),
    );
    if (unknownFields.length > 0) {
      // The reader drops these at merge time, so storing them would leave an
      // admin certain they changed something that does nothing, forever.
      throw new BadRequestException(
        `Unknown field(s) for '${key}': ${unknownFields.join(', ')}. ` +
          `Valid fields: ${Object.keys(this.defaultDocumentFor(key)).join(', ')}.`,
      );
    }

    const { data: existing, error: readError } = await this.supabase.client
      .from('feed_settings')
      .select('value, updated_at')
      .eq('key', key)
      .maybeSingle();

    if (readError) {
      throw new Error(`Failed to read feed settings '${key}': ${readError.message}`);
    }

    const now = new Date().toISOString();

    if (!existing) {
      const { error } = await this.supabase.client
        .from('feed_settings')
        .insert({ key, value: patch, updated_at: now });
      if (error) {
        throw new ConflictException(
          `Feed settings '${key}' was created concurrently. Re-read and retry.`,
        );
      }
    } else {
      const current = (existing as { value: unknown }).value;
      const merged = {
        ...(current && typeof current === 'object' && !Array.isArray(current)
          ? (current as Record<string, unknown>)
          : {}),
        ...patch,
      };

      const { data: updated, error } = await this.supabase.client
        .from('feed_settings')
        .update({ value: merged, updated_at: now })
        .eq('key', key)
        .eq('updated_at', (existing as { updated_at: string }).updated_at)
        .select('key');

      if (error) throw new Error(`Failed to update feed settings '${key}': ${error.message}`);
      if (!updated || updated.length === 0) {
        throw new ConflictException(
          `Feed settings '${key}' changed while this edit was in flight. ` +
            `Re-read GET /admin/feed/settings and retry.`,
        );
      }
    }

    this.logger.warn(
      `[FEED][SETTINGS] '${key}' updated by admin (fields: ${Object.keys(patch).join(', ')}) — ` +
        `ranking changes within ${CACHE_TTL_MS / 1000}s`,
    );
    this.invalidate();
  }

  /**
   * Admin: drop one override so the compiled default takes over again.
   *
   * This is the rollback lever, and it is the reason this surface is safer than
   * the SQL console it replaces. Reverting a bad hand-written edit today
   * requires knowing what the value was BEFORE it was overwritten; here it is
   * one call, and the value it reverts to is the one asserted by the ranking
   * regression tests.
   */
  async adminReset(key: FeedSettingsKey): Promise<void> {
    const { error } = await this.supabase.client.from('feed_settings').delete().eq('key', key);

    if (error) throw new Error(`Failed to reset feed settings '${key}': ${error.message}`);
    this.logger.warn(`[FEED][SETTINGS] '${key}' reset to compiled default by admin`);
    this.invalidate();
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
