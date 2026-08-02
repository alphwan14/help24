import { Body, Controller, Get, HttpCode, HttpStatus, Param, Post, Query } from '@nestjs/common';
import { ReviewsService } from './reviews.service';
import { CreateReviewDto } from './dto/create-review.dto';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { Auth } from '../common/auth/auth.decorator';

/**
 * Review submission + eligibility. Public/participant-facing (the reviewer is a
 * Firebase user). All authorization + eligibility is enforced in the service.
 * Read of a provider's reviews lives in the reputation controller
 * (GET /reviews/provider/:providerId).
 */
@Controller()
export class ReviewsController {
  constructor(private readonly reviews: ReviewsService) {}

  @RateLimit('reviews:write')
  @Post('reviews')
  @HttpCode(HttpStatus.CREATED)
  // NOTE THE FIELD NAME: the reviewer is `client_id`, not `user_id`. This is
  // exactly why bindings are declared per route rather than inferred from a
  // naming convention — a convention would have missed this one silently, and a
  // reviewer identity that is not bound is a reputation-farming primitive.
  // Eligibility (completed job, not self-review) is re-checked in the service.
  @Auth('body.client_id')
  create(@Body() dto: CreateReviewDto) {
    return this.reviews.createReview(dto);
  }

  @RateLimit('general:read')
  @Get('reviews/eligibility/:postId')
  @Auth('query.user_id')
  eligibility(@Param('postId') postId: string, @Query('user_id') userId: string) {
    return this.reviews.checkEligibility(postId, userId);
  }
}
