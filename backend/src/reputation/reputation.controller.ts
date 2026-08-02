import { Controller, Get, Param, Query } from '@nestjs/common';
import { ReputationService } from './reputation.service';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { Public } from '../common/auth/auth.decorator';

/**
 * Public, read-only reputation surface. Backend-mediated so the mobile app never
 * reads the RLS-protected reviews / provider_reputation tables directly.
 *
 * Review CREATION is intentionally NOT here — it belongs to Phase 3.2D and must
 * go through the eligibility-gated submission endpoint.
 */
// Ratings and reviews are what a prospective client reads BEFORE deciding to
// sign up — the surface exists to be seen by people without accounts. Both
// routes return only already-public profile information (the service filters to
// visible reviews), so there is nothing here an account would entitle you to.
@Controller()
@Public('Provider ratings and reviews are public profile information, readable before sign-up.')
export class ReputationController {
  constructor(private readonly reputation: ReputationService) {}

  /**
   * Reputation summaries for a LIST of providers — `?ids=a,b,c`.
   *
   * The surface this exists for is an applicant list: a client comparing N
   * strangers side by side. Fetching those one at a time is what made the list
   * arrive in pieces, and made a stalled connection show as N independent
   * "unavailable" cards instead of one honest state for the screen.
   *
   * Declared BEFORE `reputation/:providerId` so `/reputation?ids=…` cannot be
   * matched as a provider literally named "reputation" by a future refactor of
   * the path. Capped at 100 ids — past that the caller should be paginating.
   */
  @RateLimit('general:read')
  @Get('reputation')
  getReputationMany(@Query('ids') ids?: string) {
    const list = (ids ?? '')
      .split(',')
      .map((id) => id.trim())
      .filter((id) => id.length > 0)
      .slice(0, 100);
    return this.reputation.getReputationMany(list);
  }

  /** Reputation summary for a provider profile. */
  @RateLimit('general:read')
  @Get('reputation/:providerId')
  getReputation(@Param('providerId') providerId: string) {
    return this.reputation.getReputation(providerId);
  }

  /** Visible reviews for a provider (paginated, newest first). */
  @RateLimit('general:read')
  @Get('reviews/provider/:providerId')
  listProviderReviews(
    @Param('providerId') providerId: string,
    @Query('limit') limit?: string,
    @Query('cursor') cursor?: string,
  ) {
    const parsed = parseInt(limit ?? '20', 10);
    const safeLimit = Math.min(Math.max(Number.isFinite(parsed) ? parsed : 20, 1), 50);
    return this.reputation.listProviderReviews(providerId, safeLimit, cursor);
  }
}
