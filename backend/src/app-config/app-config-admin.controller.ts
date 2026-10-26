import {
  BadRequestException,
  Body,
  Controller,
  Get,
  Param,
  Patch,
  UseGuards,
} from '@nestjs/common';
import { AdminAuthGuard } from '../admin/auth/admin-auth.guard';
import { AdminContext } from '../admin/auth/admin-role';
import { AdminAuth } from '../common/auth/auth.decorator';
import { CurrentAdmin, Roles } from '../admin/auth/roles.decorator';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { AppConfigService } from './app-config.service';

/** "major.minor.patch", or '' for "no gate" — what the app compares. */
const VERSION = /^(\d+\.\d+\.\d+)?$/;

/**
 * Admin write surface for the client configuration plane. Same guard + role
 * model as the promotion settings it mirrors: reads for any admin, writes for
 * senior_admin+ — flipping a kill switch or a version gate is an operational
 * action with user-visible blast radius.
 *
 * The key allowlist is the contract itself (CLIENT_CONFIG_KEYS via
 * `isClientKey`), so a typo'd key is a 400 here rather than a silent row the
 * reader would ignore anyway.
 *
 * A write is `{ value, reason }`: the reason and the admin are recorded with
 * the change (migration 125). The dashboard's App controls page is the one
 * caller.
 */
@Controller('admin/config')
@UseGuards(AdminAuthGuard)
@RateLimit('admin:api')
@AdminAuth()
export class AppConfigAdminController {
  constructor(private readonly config: AppConfigService) {}

  @Get()
  @Roles('support_agent')
  async getConfig() {
    return this.config.clientConfig();
  }

  @Patch(':key')
  @Roles('senior_admin')
  async updateConfig(
    @Param('key') key: string,
    @Body() body: { value?: unknown; reason?: unknown },
    @CurrentAdmin() admin: AdminContext,
  ) {
    if (!this.config.isClientKey(key)) {
      throw new BadRequestException(`Unknown config key '${key}'.`);
    }
    const value = body?.value;
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      throw new BadRequestException('Config value must be a JSON object.');
    }
    const reason = typeof body.reason === 'string' ? body.reason.trim() : '';
    if (reason.length < 5 || reason.length > 500) {
      throw new BadRequestException('Give a reason for the change, in 5 to 500 characters.');
    }
    if (key === 'ops.min_version') {
      const v = value as Record<string, unknown>;
      for (const field of ['soft', 'hard'] as const) {
        if (v[field] !== undefined && (typeof v[field] !== 'string' || !VERSION.test(v[field] as string))) {
          throw new BadRequestException(`min_version.${field} must look like 1.0.5, or be empty for no gate.`);
        }
      }
    }
    const { recorded } = await this.config.adminSet(admin, key, value as Record<string, unknown>, reason);
    return { ...(await this.config.clientConfig()), recorded };
  }
}
