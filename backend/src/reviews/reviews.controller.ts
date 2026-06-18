import { Body, Controller, Get, HttpCode, HttpStatus, Param, Post, Query } from '@nestjs/common';
import { ReviewsService } from './reviews.service';
import { CreateReviewDto } from './dto/create-review.dto';

/**
 * Review submission + eligibility. Public/participant-facing (the reviewer is a
 * Firebase user). All authorization + eligibility is enforced in the service.
 * Read of a provider's reviews lives in the reputation controller
 * (GET /reviews/provider/:providerId).
 */
@Controller()
export class ReviewsController {
  constructor(private readonly reviews: ReviewsService) {}

  @Post('reviews')
  @HttpCode(HttpStatus.CREATED)
  create(@Body() dto: CreateReviewDto) {
    return this.reviews.createReview(dto);
  }

  @Get('reviews/eligibility/:postId')
  eligibility(@Param('postId') postId: string, @Query('user_id') userId: string) {
    return this.reviews.checkEligibility(postId, userId);
  }
}
