import { BadRequestException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';

/**
 * Package registry reads/updates. Pricing lives ONLY in promotion_packages —
 * services snapshot a package onto the campaign at purchase time, so editing a
 * package here never rewrites anything already sold.
 */

export interface PromotionPackageRow {
  id: string;
  name: string;
  description: string;
  price_kes: number | null; // null only when is_custom
  duration_days: number;
  placements: string[];
  is_custom: boolean;
  sort: number;
  active: boolean;
  created_at: string;
  updated_at: string;
}

const PACKAGE_COLUMNS =
  'id, name, description, price_kes, duration_days, placements, is_custom, sort, active, created_at, updated_at';

const CACHE_TTL_MS = 60_000;

@Injectable()
export class PackagesService {
  private readonly logger = new Logger(PackagesService.name);
  private cache: { rows: PromotionPackageRow[]; expiresAt: number } | null = null;

  constructor(private readonly supabase: SupabaseService) {}

  /** Active packages, cheapest-first by sort — the public pricing list. */
  async listActive(): Promise<PromotionPackageRow[]> {
    const now = Date.now();
    if (this.cache && now < this.cache.expiresAt) return this.cache.rows;

    const { data, error } = await this.supabase.client
      .from('promotion_packages')
      .select(PACKAGE_COLUMNS)
      .eq('active', true)
      .order('sort', { ascending: true });

    if (error) {
      this.logger.error(`[PROMO][PACKAGES] list failed: ${error.message}`);
      return this.cache?.rows ?? [];
    }

    const rows = (data ?? []) as PromotionPackageRow[];
    this.cache = { rows, expiresAt: now + CACHE_TTL_MS };
    return rows;
  }

  /** An active package by id, or 404. */
  async getActive(id: string): Promise<PromotionPackageRow> {
    const rows = await this.listActive();
    const pkg = rows.find((p) => p.id === id);
    if (!pkg) throw new NotFoundException(`Package '${id}' not found or inactive.`);
    return pkg;
  }

  // ── Admin ──────────────────────────────────────────────────────────────────

  async adminList(): Promise<PromotionPackageRow[]> {
    const { data, error } = await this.supabase.client
      .from('promotion_packages')
      .select(PACKAGE_COLUMNS)
      .order('sort', { ascending: true });

    if (error) throw new Error(`Failed to list packages: ${error.message}`);
    return (data ?? []) as PromotionPackageRow[];
  }

  /**
   * Admin: patch a package. Only presentation/pricing fields are editable;
   * the slug is permanent (campaign snapshots + analytics key on it).
   */
  async adminUpdate(
    id: string,
    patch: Partial<Pick<PromotionPackageRow, 'name' | 'description' | 'price_kes' | 'duration_days' | 'sort' | 'active'>>,
  ): Promise<PromotionPackageRow> {
    const { data: existing, error: findError } = await this.supabase.client
      .from('promotion_packages')
      .select(PACKAGE_COLUMNS)
      .eq('id', id)
      .maybeSingle();

    if (findError) throw new Error(`Failed to load package '${id}': ${findError.message}`);
    if (!existing) throw new NotFoundException(`Package '${id}' not found.`);

    const isCustom = (existing as PromotionPackageRow).is_custom;
    if (patch.price_kes !== undefined) {
      if (patch.price_kes === null && !isCustom) {
        throw new BadRequestException('Only custom (enterprise) packages may have no price.');
      }
      if (patch.price_kes !== null && (!Number.isInteger(patch.price_kes) || patch.price_kes <= 0)) {
        throw new BadRequestException('price_kes must be a positive whole number of KES.');
      }
    }
    if (patch.duration_days !== undefined && (!Number.isInteger(patch.duration_days) || patch.duration_days <= 0)) {
      throw new BadRequestException('duration_days must be a positive whole number.');
    }

    const { data, error } = await this.supabase.client
      .from('promotion_packages')
      .update({ ...patch, updated_at: new Date().toISOString() })
      .eq('id', id)
      .select(PACKAGE_COLUMNS)
      .single();

    if (error) throw new Error(`Failed to update package '${id}': ${error.message}`);
    this.cache = null;
    this.logger.log(`[PROMO][PACKAGES] updated '${id}' — ${JSON.stringify(patch)}`);
    return data as PromotionPackageRow;
  }
}
