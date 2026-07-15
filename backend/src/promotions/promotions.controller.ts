import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  ParseUUIDPipe,
  Post,
  Query,
} from '@nestjs/common';
import { PackagesService } from './packages.service';
import { CampaignsService } from './campaigns.service';
import { PromotionPaymentsService } from './promotion-payments.service';
import { ServingService } from './serving.service';
import { PromotionAnalyticsService } from './analytics.service';
import {
  CreateCampaignDto,
  IngestEventsDto,
  OwnerActionDto,
  PayCampaignDto,
  SlotsQueryDto,
} from './dto/promotions.dto';

/**
 * "Promote Business" — user-facing routes.
 *
 * Follows the platform's asserted-user_id convention (jobs/mpesa/reviews):
 * the caller's Firebase UID travels in body/query and every service call
 * verifies ownership against it. Static segments precede ':id' so
 * /promotions/packages is never captured as a campaign id.
 */
@Controller('promotions')
export class PromotionsController {
  constructor(
    private readonly packages: PackagesService,
    private readonly campaigns: CampaignsService,
    private readonly payments: PromotionPaymentsService,
    private readonly serving: ServingService,
    private readonly analytics: PromotionAnalyticsService,
  ) {}

  private requireUserId(userId: string | undefined): string {
    if (!userId?.trim()) throw new BadRequestException('user_id is required.');
    return userId.trim();
  }

  // ── Public: pricing + serving ───────────────────────────────────────────────

  /** The package picker — pricing lives in the DB, never in the app. */
  @Get('packages')
  listPackages() {
    return this.packages.listActive();
  }

  /**
   * Placement engine. Called by the app in PARALLEL with its organic feed
   * read; on any internal failure it returns empty items, never an error.
   */
  @Get('slots')
  getSlots(@Query() query: SlotsQueryDto) {
    return this.serving.getSlots(query);
  }

  /** Batched impression/click/tap ingest (fire-and-forget on the client). */
  @Post('events')
  @HttpCode(HttpStatus.ACCEPTED)
  ingestEvents(@Body() dto: IngestEventsDto) {
    return this.analytics.ingest(dto.events);
  }

  // ── Campaigns ───────────────────────────────────────────────────────────────

  /** Promote Business step 1: campaign for an owned, open offer post. */
  @Post('campaigns')
  createCampaign(@Body() dto: CreateCampaignDto) {
    return this.campaigns.create({
      userId: dto.user_id,
      postId: dto.post_id,
      packageId: dto.package_id,
    });
  }

  @Get('campaigns')
  listCampaigns(@Query('user_id') userId?: string) {
    return this.campaigns.listByOwner(this.requireUserId(userId));
  }

  /** Payment history for Profile → Promote Business → Payments. */
  @Get('payments')
  listPayments(@Query('user_id') userId?: string) {
    return this.payments.listByPayer(this.requireUserId(userId));
  }

  @Get('campaigns/:id')
  getCampaign(@Param('id', ParseUUIDPipe) id: string, @Query('user_id') userId?: string) {
    return this.campaigns.getOwned(id, this.requireUserId(userId));
  }

  // ── Payment ─────────────────────────────────────────────────────────────────

  /** Promote Business step 2: M-Pesa STK push for the campaign's package price. */
  @Post('campaigns/:id/pay')
  pay(@Param('id', ParseUUIDPipe) id: string, @Body() dto: PayCampaignDto) {
    return this.payments.initiate(id, dto.user_id, dto.phone);
  }

  /** Poll target while the STK prompt is on the payer's phone. */
  @Get('campaigns/:id/payment-status')
  paymentStatus(@Param('id', ParseUUIDPipe) id: string, @Query('user_id') userId?: string) {
    return this.payments.statusForCampaign(id, this.requireUserId(userId));
  }

  // ── Owner lifecycle ─────────────────────────────────────────────────────────

  @Post('campaigns/:id/pause')
  pause(@Param('id', ParseUUIDPipe) id: string, @Body() dto: OwnerActionDto) {
    return this.campaigns.pause(id, dto.user_id);
  }

  @Post('campaigns/:id/resume')
  resume(@Param('id', ParseUUIDPipe) id: string, @Body() dto: OwnerActionDto) {
    return this.campaigns.resume(id, dto.user_id);
  }

  @Post('campaigns/:id/cancel')
  cancel(@Param('id', ParseUUIDPipe) id: string, @Body() dto: OwnerActionDto) {
    return this.campaigns.cancel(id, dto.user_id, dto.reason);
  }

  // ── Analytics ───────────────────────────────────────────────────────────────

  /** "Is promoting my business working?" — the owner dashboard. */
  @Get('campaigns/:id/analytics')
  campaignAnalytics(@Param('id', ParseUUIDPipe) id: string, @Query('user_id') userId?: string) {
    return this.analytics.dashboard(id, this.requireUserId(userId));
  }
}
