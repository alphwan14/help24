import { Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';

/**
 * Serving/moderation knobs from promotion_settings, merged over code defaults
 * so a missing row/key can never break serving. Cached briefly — these values
 * sit on the feed hot path.
 */

export interface ServingSettings {
  discover_first_after: number; // organic cards before the first sponsored slot
  discover_gap: number;         // organic cards between sponsored slots
  discover_max_slots: number;
  search_max_slots: number;
  category_max_slots: number;
  nearby_max_slots: number;
  nearby_max_radius_km: number;
}

export interface ModerationSettings {
  auto_approve: boolean;
}

export interface PaymentSettings {
  awaiting_payment_ttl_hours: number;
}

const DEFAULTS: { serving: ServingSettings; moderation: ModerationSettings; payment: PaymentSettings } = {
  serving: {
    discover_first_after: 7,
    discover_gap: 8,
    discover_max_slots: 3,
    search_max_slots: 2,
    category_max_slots: 2,
    nearby_max_slots: 2,
    nearby_max_radius_km: 30,
  },
  moderation: { auto_approve: false },
  payment: { awaiting_payment_ttl_hours: 24 },
};

const CACHE_TTL_MS = 60_000;

@Injectable()
export class PromotionSettingsService {
  private readonly logger = new Logger(PromotionSettingsService.name);
  private cache: { rows: Record<string, Record<string, unknown>>; expiresAt: number } | null = null;

  constructor(private readonly supabase: SupabaseService) {}

  private async loadRows(): Promise<Record<string, Record<string, unknown>>> {
    const now = Date.now();
    if (this.cache && now < this.cache.expiresAt) return this.cache.rows;

    const { data, error } = await this.supabase.client
      .from('promotion_settings')
      .select('key, value');

    if (error) {
      this.logger.error(`[PROMO][SETTINGS] load failed — using defaults: ${error.message}`);
      return this.cache?.rows ?? {};
    }

    const rows: Record<string, Record<string, unknown>> = {};
    for (const row of data ?? []) {
      rows[row.key as string] = (row.value ?? {}) as Record<string, unknown>;
    }
    this.cache = { rows, expiresAt: now + CACHE_TTL_MS };
    return rows;
  }

  private merge<T extends object>(defaults: T, stored?: Record<string, unknown>): T {
    if (!stored) return { ...defaults };
    const out = { ...(defaults as Record<string, unknown>) };
    for (const [k, v] of Object.entries(stored)) {
      if (k in out && typeof v === typeof out[k]) out[k] = v;
    }
    return out as T;
  }

  async serving(): Promise<ServingSettings> {
    const rows = await this.loadRows();
    return this.merge(DEFAULTS.serving, rows['serving']);
  }

  async moderation(): Promise<ModerationSettings> {
    const rows = await this.loadRows();
    return this.merge(DEFAULTS.moderation, rows['moderation']);
  }

  async payment(): Promise<PaymentSettings> {
    const rows = await this.loadRows();
    return this.merge(DEFAULTS.payment, rows['payment']);
  }

  /** Admin: replace one settings document (validated by the caller). */
  async adminUpdate(key: 'serving' | 'moderation' | 'payment', value: Record<string, unknown>): Promise<void> {
    const { error } = await this.supabase.client
      .from('promotion_settings')
      .upsert({ key, value, updated_at: new Date().toISOString() });

    if (error) throw new Error(`Failed to update promotion settings '${key}': ${error.message}`);
    this.cache = null; // next read refetches
  }
}
