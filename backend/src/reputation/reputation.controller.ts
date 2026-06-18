import { Controller, Get, Param, Query } from '@nestjs/common';
import { ReputationService } from './reputation.service';

/**
 * Public, read-only reputation surface. Backend-mediated so the mobile app never
 * reads the RLS-protected reviews / provider_reputation tables directly.
 *
 * Review CREATION is intentionally NOT here — it belongs to Phase 3.2D and must
 * go through the eligibility-gated submission endpoint.
 */
@Controller()
export class ReputationController {
  constructor(private readonly reputation: ReputationService) {}

  /** Reputation summary for a provider profile. */
  @Get('reputation/:providerId')
  getReputation(@Param('providerId') providerId: string) {
    return this.reputation.getReputation(providerId);
  }

  /** Visible reviews for a provider (paginated, newest first). */
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
