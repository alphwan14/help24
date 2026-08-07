import { createHash } from 'crypto';
import { Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import {
  CLIENT_CONFIG_KEYS,
  ClientConfig,
  ClientConfigKey,
  DEFAULT_CLIENT_CONFIG,
} from './client-config';

/**
 * Client configuration: `app_settings` merged OVER the compiled defaults.
 *
 * Same service shape as FeedSettingsService, deliberately — that pattern has
 * already proven the property being bought here: a config surface that can be
 * edited at runtime but can never take the product down, because every layer
 * degrades to the compiled defaults.
 *
 * Three layers of safety, in order of how likely each is to matter:
 *   1. a failed query (including "table does not exist" — the migration ships
 *      after this code) keeps the last good cache, or the defaults;
 *   2. a missing key keeps that whole section's defaults;
 *   3. a key present with the wrong TYPE is ignored, key by key — one
 *      fat-fingered value in the SQL editor degrades exactly one field.
 *
 * Cached 60 s: /config is polled by every client on launch and resume, and a
 * minute is well inside the feedback loop of an operator flipping a switch.
 *
 * VERSIONING
 * ----------
 * `version` is a hash of the canonical merged payload — no timestamps, no
 * randomness — so identical config always hashes identically. It serves as
 * the ETag, which is what makes the steady-state cost of this endpoint a 304
 * with an empty body rather than a payload.
 */

const CACHE_TTL_MS = 60_000;

export interface VersionedClientConfig {
  version: string;
  config: ClientConfig;
}

@Injectable()
export class AppConfigService {
  private readonly logger = new Logger(AppConfigService.name);

  /**
   * The last successfully merged config, and when it stops being fresh — held
   * as TWO fields rather than one nullable cache object, deliberately.
   *
   * Dropping the value and the expiry together (the shape FeedSettingsService
   * uses) means `invalidate()` also throws away the last known-good document.
   * That is harmless for ranking weights. It is not harmless here: the sequence
   * "admin flips a kill switch → invalidate → next read hits a DB blip" would
   * serve DEFAULTS, which turns every switch back on — the exact opposite of
   * what the operator just asked for, at the exact moment they were reacting to
   * an incident. Keeping `lastGood` independent of `expiresAt` means
   * invalidation only forces a refetch; it never forgets.
   */
  private lastGood: VersionedClientConfig | null = null;
  private expiresAt = 0;

  constructor(private readonly supabase: SupabaseService) {}

  async clientConfig(): Promise<VersionedClientConfig> {
    const now = Date.now();
    if (this.lastGood && now < this.expiresAt) return this.lastGood;

    const { data, error } = await this.supabase.client.from('app_settings').select('key, value');

    if (error) {
      // Migration not applied yet, or a transient outage. Either way clients
      // keep receiving a complete, valid config — never an error, never a
      // partial document.
      this.logger.warn(`[CONFIG] load failed — serving defaults: ${error.message}`);
      const value = this.lastGood ?? this.versioned(DEFAULT_CLIENT_CONFIG);
      // Re-stamp so a persistent outage does not query on every single request;
      // the value itself is retained either way.
      this.lastGood = value;
      this.expiresAt = now + CACHE_TTL_MS;
      return value;
    }

    const rows: Partial<Record<ClientConfigKey, Record<string, unknown>>> = {};
    for (const row of data ?? []) {
      const key = (row as { key: string }).key;
      const value = (row as { value: unknown }).value;
      if (!this.isClientKey(key)) continue; // server-only rows never reach the response
      if (value && typeof value === 'object' && !Array.isArray(value)) {
        rows[key] = value as Record<string, unknown>;
      }
    }

    const value = this.versioned(this.build(rows));
    this.lastGood = value;
    this.expiresAt = now + CACHE_TTL_MS;
    return value;
  }

  /**
   * Force the next read to refetch (admin edits, tests). The last known-good
   * document is deliberately KEPT as the error-path fallback — see the field
   * comment above.
   */
  invalidate(): void {
    this.expiresAt = 0;
  }

  /** Admin: replace one settings document. Key must belong to the contract. */
  async adminUpdate(key: ClientConfigKey, value: Record<string, unknown>): Promise<void> {
    const { error } = await this.supabase.client
      .from('app_settings')
      .upsert({ key, value, updated_at: new Date().toISOString() });

    if (error) throw new Error(`Failed to update app settings '${key}': ${error.message}`);
    this.invalidate();
  }

  isClientKey(key: string): key is ClientConfigKey {
    return (CLIENT_CONFIG_KEYS as readonly string[]).includes(key);
  }

  // ── merge helpers ──────────────────────────────────────────────────────────

  /**
   * Shallow merge with a per-key type guard. A stored value only wins when it
   * has the same JavaScript type as the default it replaces; wrong-typed and
   * non-finite values are dropped and the default stands.
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

  private build(rows: Partial<Record<ClientConfigKey, Record<string, unknown>>>): ClientConfig {
    const d = DEFAULT_CLIENT_CONFIG;
    const config: ClientConfig = {
      ops: {
        kill_switches: this.merge(d.ops.kill_switches, rows['ops.kill_switches']),
        maintenance: this.merge(d.ops.maintenance, rows['ops.maintenance']),
        min_version: this.merge(d.ops.min_version, rows['ops.min_version']),
        announcement: this.merge(d.ops.announcement, rows['ops.announcement']),
      },
      tuning: {
        payments: this.merge(d.tuning.payments, rows['tuning.payments']),
        listings: this.merge(d.tuning.listings, rows['tuning.listings']),
      },
    };

    // Tuning values are timers and budgets; zero or negative would wedge the
    // client loops they drive. Clamp to sane floors rather than trusting the
    // type guard alone — a well-typed nonsense value is still nonsense.
    const p = config.tuning.payments;
    p.poll_interval_seconds = Math.min(Math.max(Math.round(p.poll_interval_seconds), 2), 60);
    p.poll_budget = Math.min(Math.max(Math.round(p.poll_budget), 6), 120);
    const l = config.tuning.listings;
    l.urgent_window_minutes = Math.min(Math.max(Math.round(l.urgent_window_minutes), 5), 24 * 60);

    return config;
  }

  private versioned(config: ClientConfig): VersionedClientConfig {
    // Canonical because build() constructs the object in a fixed key order from
    // the contract — JSON.stringify is deterministic over it.
    const version = createHash('sha256').update(JSON.stringify(config)).digest('hex').slice(0, 16);
    return { version, config };
  }
}
