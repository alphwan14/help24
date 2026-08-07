import {
  BadRequestException,
  Body,
  Controller,
  Delete,
  Get,
  Param,
  Patch,
  UseGuards,
} from '@nestjs/common';
import { AdminAuthGuard } from '../admin/auth/admin-auth.guard';
import { AdminAuth } from '../common/auth/auth.decorator';
import { Roles } from '../admin/auth/roles.decorator';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { FeedSettingsService, FEED_SETTINGS_KEYS } from './feed-settings.service';
import { DEFAULT_FEED_CONFIG } from './ranking/defaults';

/**
 * Admin write surface for Discover ranking (`feed_settings`).
 *
 * WHY THIS EXISTS
 * ---------------
 * `feed_settings` shipped with a merge-over-defaults reader and thirteen
 * populated rows in production — but no way to write them. Promotion settings
 * have an admin surface; the client config plane has one; ranking, the thing
 * tuned most often, had none. The only way to retune Discover was hand-written
 * SQL against the production table, with no key validation, no audit line, and
 * no way back to the previous value once it had been overwritten.
 *
 * That is the whole gap this closes. It adds no new capability that SQL did not
 * already have — it adds the guard rails around it.
 *
 * WHAT MAKES IT SAFE
 * ------------------
 *  • The key allowlist is `FEED_SETTINGS_KEYS`, so a typo is a 400 rather than
 *    a row the reader ignores while the admin believes they changed something.
 *    Field names are checked the same way, for the same reason.
 *  • `PATCH` MERGES. Every document in production is a full document — the
 *    `weights` row carries all fifteen entries — so a replacing write of one
 *    field would silently drop the rest to compiled defaults.
 *  • The merge is guarded on `updated_at`, so two admins editing in the same
 *    minute get a 409 rather than one edit disappearing.
 *  • Writes are `senior_admin`; reads are `support_agent`. Ranking is revenue
 *    and supply distribution, not a display preference.
 *  • Every write and reset logs a WARN naming the key and the fields touched.
 *  • `DELETE` restores the compiled default — the reversibility that raw SQL
 *    never had.
 *  • The reader's per-key type guard still stands behind all of this: a
 *    wrong-typed value is dropped at merge time and the default survives.
 *
 * WHAT IT DELIBERATELY DOES NOT DO
 * --------------------------------
 * It does not validate ranges. A weight of 30 and a weight of 3000 are both
 * numbers, and picking "sensible" bounds here would be inventing policy that
 * the ranking regression suite already expresses better. The mitigation for a
 * bad value is `DELETE`, which is one call and always available.
 */
@Controller('admin/feed/settings')
@UseGuards(AdminAuthGuard)
@RateLimit('admin:api')
@AdminAuth()
export class FeedSettingsAdminController {
  constructor(private readonly settings: FeedSettingsService) {}

  /**
   * The effective ranking config, the raw stored overrides, and the compiled
   * defaults — together.
   *
   * Returning all three is the point. The merged document alone cannot tell you
   * whether `weights.distance = 30` is pinned in the table or is simply the
   * default showing through, and that is precisely what someone about to retune
   * needs to know.
   */
  @Get()
  @Roles('support_agent')
  async getSettings() {
    const [effective, stored] = await Promise.all([
      this.settings.config(),
      this.settings.storedOverrides(),
    ]);

    return {
      effective,
      stored,
      defaults: DEFAULT_FEED_CONFIG,
      overridden_keys: Object.keys(stored).sort(),
      available_keys: [...FEED_SETTINGS_KEYS],
    };
  }

  /** Replace one settings document. Returns the resulting effective config. */
  @Patch(':key')
  @Roles('senior_admin')
  async updateSettings(@Param('key') key: string, @Body() value: Record<string, unknown>) {
    if (!this.settings.isSettingsKey(key)) {
      throw new BadRequestException(
        `Unknown feed settings key '${key}'. Valid keys: ${FEED_SETTINGS_KEYS.join(', ')}.`,
      );
    }
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      throw new BadRequestException('Feed settings value must be a JSON object.');
    }

    await this.settings.adminUpdate(key, value);
    return { key, effective: await this.settings.config() };
  }

  /** Drop one override so the compiled default applies again. */
  @Delete(':key')
  @Roles('senior_admin')
  async resetSettings(@Param('key') key: string) {
    if (!this.settings.isSettingsKey(key)) {
      throw new BadRequestException(
        `Unknown feed settings key '${key}'. Valid keys: ${FEED_SETTINGS_KEYS.join(', ')}.`,
      );
    }

    await this.settings.adminReset(key);
    return { key, reset_to_default: true, effective: await this.settings.config() };
  }
}
