import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  ParseUUIDPipe,
  Patch,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { AdminAuthGuard } from '../admin/auth/admin-auth.guard';
import { CurrentAdmin, Roles } from '../admin/auth/roles.decorator';
import { AdminContext } from '../admin/auth/admin-role';
import { CampaignsService } from './campaigns.service';
import { PackagesService } from './packages.service';
import { PromotionPaymentsService } from './promotion-payments.service';
import { PromotionAnalyticsService } from './analytics.service';
import { PromotionSettingsService } from './settings.service';
import { isCampaignStatus } from './campaign-state';
import { AdminCancelDto, RejectCampaignDto, UpdatePackageDto } from './dto/promotions.dto';

/**
 * Admin surface for Business Promotion: moderation queue (approve/reject),
 * campaign oversight, package/pricing management, revenue and serving knobs.
 * Same guard + role model as the Disputes Centre — reads for any admin,
 * money/moderation writes for senior_admin+.
 */
@Controller('admin/promotions')
@UseGuards(AdminAuthGuard)
export class PromotionsAdminController {
  constructor(
    private readonly campaigns: CampaignsService,
    private readonly packages: PackagesService,
    private readonly payments: PromotionPaymentsService,
    private readonly analytics: PromotionAnalyticsService,
    private readonly settings: PromotionSettingsService,
  ) {}

  // ── Campaigns ───────────────────────────────────────────────────────────────

  @Get('campaigns')
  @Roles('support_agent')
  list(@Query('status') status?: string) {
    if (status === undefined) return this.campaigns.adminList();
    if (!isCampaignStatus(status)) {
      throw new BadRequestException(`Unknown campaign status '${status}'.`);
    }
    return this.campaigns.adminList(status);
  }

  @Get('campaigns/:id')
  @Roles('support_agent')
  get(@Param('id', ParseUUIDPipe) id: string) {
    return this.campaigns.adminGet(id);
  }

  @Get('campaigns/:id/analytics')
  @Roles('support_agent')
  analyticsFor(@Param('id', ParseUUIDPipe) id: string) {
    return this.analytics.dashboard(id, null, { requireOwner: false });
  }

  // ── Moderation ──────────────────────────────────────────────────────────────

  @Post('campaigns/:id/approve')
  @Roles('senior_admin')
  @HttpCode(HttpStatus.OK)
  approve(@Param('id', ParseUUIDPipe) id: string, @CurrentAdmin() admin: AdminContext) {
    return this.campaigns.approve(id, admin.id);
  }

  @Post('campaigns/:id/reject')
  @Roles('senior_admin')
  @HttpCode(HttpStatus.OK)
  reject(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: RejectCampaignDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.campaigns.reject(id, admin.id, dto.reason);
  }

  // ── Oversight ───────────────────────────────────────────────────────────────

  @Post('campaigns/:id/pause')
  @Roles('senior_admin')
  @HttpCode(HttpStatus.OK)
  pause(@Param('id', ParseUUIDPipe) id: string, @CurrentAdmin() admin: AdminContext) {
    return this.campaigns.adminPause(id, admin.id);
  }

  @Post('campaigns/:id/resume')
  @Roles('senior_admin')
  @HttpCode(HttpStatus.OK)
  resume(@Param('id', ParseUUIDPipe) id: string, @CurrentAdmin() admin: AdminContext) {
    return this.campaigns.adminResume(id, admin.id);
  }

  @Post('campaigns/:id/cancel')
  @Roles('senior_admin')
  @HttpCode(HttpStatus.OK)
  cancel(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: AdminCancelDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.campaigns.adminCancel(id, admin.id, dto.reason);
  }

  // ── Packages (pricing lives here, never in code) ────────────────────────────

  @Get('packages')
  @Roles('support_agent')
  listPackages() {
    return this.packages.adminList();
  }

  @Patch('packages/:id')
  @Roles('senior_admin')
  updatePackage(@Param('id') id: string, @Body() dto: UpdatePackageDto) {
    return this.packages.adminUpdate(id, dto);
  }

  // ── Revenue ─────────────────────────────────────────────────────────────────

  @Get('revenue')
  @Roles('senior_admin')
  revenue() {
    return this.payments.revenueSummary();
  }

  // ── Serving/moderation knobs ────────────────────────────────────────────────

  @Get('settings')
  @Roles('senior_admin')
  async getSettings() {
    const [serving, moderation, payment] = await Promise.all([
      this.settings.serving(),
      this.settings.moderation(),
      this.settings.payment(),
    ]);
    return { serving, moderation, payment };
  }

  @Patch('settings/:key')
  @Roles('senior_admin')
  async updateSettings(@Param('key') key: string, @Body() value: Record<string, unknown>) {
    if (key !== 'serving' && key !== 'moderation' && key !== 'payment') {
      throw new BadRequestException(`Unknown settings key '${key}'.`);
    }
    await this.settings.adminUpdate(key, value);
    return this.getSettings();
  }
}
