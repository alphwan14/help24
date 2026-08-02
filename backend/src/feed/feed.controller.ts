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
import { Auth, Public } from '../common/auth/auth.decorator';

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
  // Anonymous browsing is the product's front door and must keep working
  // exactly as it does today — a cold-start request with no user, no
  // coordinates and no filters returns a ranked feed.
  //
  // The binding covers the signed-in case: `user_id` selects whose behaviour
  // profile, skills and applied-posts shape the ranking, so accepting it
  // unproven lets anyone request another person's personalised feed by naming
  // them — a read of what someone has been searching for and applying to.
  // Bound, the query personalises for the caller or for nobody.
  @Public('Discover is browsable without an account.', { bind: 'query.user_id' })
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
  // `user_id` is REQUIRED by the DTO, so this route is never called by an
  // anonymous browser — the client only reaches it once someone is signed in.
  // Binding it matters more than the telemetry framing suggests: these events
  // are the behavioural signal the recommendation engine ranks on, so an
  // unbound user_id is a write into another person's ranking profile.
  @Auth('body.user_id')
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
  // Writes a ranking signal onto the caller's own provider profile.
  @Auth('body.user_id')
  async setAvailability(@Body() dto: SetAvailabilityDto): Promise<{ available_until: string | null }> {
    return this.feed.setAvailability(dto);
  }
}
