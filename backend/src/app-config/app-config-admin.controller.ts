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
import { AdminAuth } from '../common/auth/auth.decorator';
import { Roles } from '../admin/auth/roles.decorator';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { AppConfigService } from './app-config.service';

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
 * Until the `app_settings` migration is applied this surface fails with a
 * clear error on write — by design; the read path serves defaults regardless.
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
  async updateConfig(@Param('key') key: string, @Body() value: Record<string, unknown>) {
    if (!this.config.isClientKey(key)) {
      throw new BadRequestException(`Unknown config key '${key}'.`);
    }
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      throw new BadRequestException('Config value must be a JSON object.');
    }
    await this.config.adminUpdate(key, value);
    return this.config.clientConfig();
  }
}
