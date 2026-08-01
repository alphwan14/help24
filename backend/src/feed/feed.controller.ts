import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Logger,
  Post,
  Query,
  ServiceUnavailableException,
} from '@nestjs/common';
import { FeedService, FeedResponse } from './feed.service';
import { FeedQueryDto, IngestInteractionsDto, SetAvailabilityDto } from './dto/feed.dto';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';

/**
 * Discover recommendation engine — public routes.
 *
 * Follows the platform's asserted-`user_id` convention (jobs / mpesa /
 * promotions): the caller's Firebase UID travels in the query or body. When
 * the platform-wide token guard lands, these routes adopt it in one place.
 *
 * WHAT `/feed` PROMISES THE CLIENT
 * --------------------------------
 * A 200 is a ranked feed. A 503 means "ranking is unavailable, use your
 * fallback" — and `FeedService` on the device answers that by reading Supabase
 * directly, exactly as it does today. That contract is why this controller
 * never returns an empty 200 to paper over an internal failure: an empty feed
 * renders as "No posts found — try adjusting your filters", which would be a
 * lie the user acts on.
 */
@Controller('feed')
export class FeedController {
  private readonly logger = new Logger(FeedController.name);

  constructor(private readonly feed: FeedService) {}

  /**
   * The ranked Discover feed.
   *
   * Every parameter is optional. An anonymous request with no coordinates and
   * no filters is the cold-start case and returns a sensible feed ranked on
   * urgency, freshness, trust and engagement.
   */
  @Get()
  @RateLimit('feed:read')
  async getFeed(@Query() query: FeedQueryDto): Promise<FeedResponse> {
    try {
      return await this.feed.getFeed(query);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      this.logger.error(`[FEED] ranking failed — client will fall back: ${message}`);
      throw new ServiceUnavailableException('Feed ranking is temporarily unavailable.');
    }
  }

  /**
   * Batched behavioural events (signals 9 and 10).
   *
   * Always 202, even when nothing was stored. This is fire-and-forget
   * telemetry from a device that has already moved on; a failure here is a
   * server-side concern and must never reach the person scrolling.
   */
  @Post('interactions')
  @HttpCode(HttpStatus.ACCEPTED)
  @RateLimit('telemetry:ingest')
  async ingest(@Body() dto: IngestInteractionsDto): Promise<{ accepted: number }> {
    return this.feed.ingestInteractions(dto);
  }

  /**
   * Set or clear a provider's "available now" window (signal 7).
   *
   * Unlike the two routes above this one DOES surface failures: the user
   * pressed a toggle and is entitled to know it did not take.
   */
  @Post('availability')
  @RateLimit('availability:toggle')
  async setAvailability(@Body() dto: SetAvailabilityDto): Promise<{ available_until: string | null }> {
    return this.feed.setAvailability(dto);
  }
}
