import { BadRequestException, ConflictException, Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { NotificationsService } from '../notifications/notifications.service';
import { ReputationService } from '../reputation/reputation.service';
import { CreateReviewDto } from './dto/create-review.dto';

const TERMINAL_DISPUTE = [
  'resolved',
  'resolved_release',
  'resolved_refund',
  'resolved_partial',
  'merged',
];

interface Gate {
  canReview: boolean;
  alreadyReviewed: boolean;
  reviewId: string | null;
  providerId: string | null;
  fromDisputedJob: boolean;
  reason: string | null;
}

/**
 * Review submission engine. Every review is gated server-side against canonical
 * data (post, job_completions, transactions, disputes, reviews) — the client is
 * never trusted. On a successful submission the provider's reputation is
 * recomputed immediately and the provider is notified.
 *
 * Submission only — no moderation, replies, or editing in this phase.
 */
@Injectable()
export class ReviewsService {
  private readonly logger = new Logger(ReviewsService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly notifications: NotificationsService,
    private readonly reputation: ReputationService,
  ) {}

  /** Eligibility for the lifecycle "Leave Review" button. */
  async checkEligibility(postId: string, userId: string) {
    const gate = await this.evaluate(postId, userId);
    return {
      can_review: gate.canReview,
      already_reviewed: gate.alreadyReviewed,
      review_id: gate.reviewId,
      provider_id: gate.providerId,
      reason: gate.reason,
    };
  }

  /** Create a review (eligibility-gated). Recomputes reputation + notifies provider. */
  async createReview(dto: CreateReviewDto) {
    const gate = await this.evaluate(dto.post_id, dto.client_id);

    if (gate.alreadyReviewed) {
      throw new ConflictException('You have already reviewed this job.');
    }
    if (!gate.canReview || !gate.providerId) {
      throw new BadRequestException(gate.reason ?? 'You cannot review this job.');
    }

    const { data, error } = await this.supabase.client
      .from('reviews')
      .insert({
        post_id: dto.post_id,
        client_id: dto.client_id,
        provider_id: gate.providerId,
        rating: dto.rating,
        comment: dto.comment?.trim() ? dto.comment.trim() : null,
        from_disputed_job: gate.fromDisputedJob,
      })
      .select('id')
      .single();

    if (error || !data) {
      // UNIQUE(post_id) race → already reviewed.
      if (error?.code === '23505') {
        throw new ConflictException('You have already reviewed this job.');
      }
      this.logger.error(`[REVIEWS] insert failed post=${dto.post_id}: ${error?.message ?? 'null'}`);
      throw new BadRequestException('Failed to submit review.');
    }

    const reviewId = data.id as string;
    this.logger.log(
      `[REVIEWS] created ${reviewId} post=${dto.post_id} provider=${gate.providerId} rating=${dto.rating}`,
    );

    // Immediate, server-authoritative reputation recompute (non-fatal).
    await this.reputation.recompute(gate.providerId);

    // Notify the provider their reputation changed.
    await this.notifications.send({
      userId: gate.providerId,
      type: 'review_received',
      title: 'New Review',
      body: `You received a ${dto.rating}★ review.`,
      data: { post_id: dto.post_id, rating: String(dto.rating) },
    });

    return { review_id: reviewId, provider_id: gate.providerId, rating: dto.rating };
  }

  // ── Eligibility evaluation (single source of truth for GET + POST) ──────────

  private async evaluate(postId: string, userId: string): Promise<Gate> {
    const deny = (reason: string, extra: Partial<Gate> = {}): Gate => ({
      canReview: false,
      alreadyReviewed: false,
      reviewId: null,
      providerId: null,
      fromDisputedJob: false,
      reason,
      ...extra,
    });

    if (!userId) return deny('Missing user.');

    const { data: post } = await this.supabase.client
      .from('posts')
      .select('id, author_user_id, selected_provider_id, status')
      .eq('id', postId)
      .maybeSingle();
    if (!post) return deny('Job not found.');

    const authorId = post.author_user_id as string;
    const providerId = (post.selected_provider_id as string | null) ?? null;

    // Existing review (one per post). Computed early so the UI can show "reviewed".
    const { data: existing } = await this.supabase.client
      .from('reviews')
      .select('id')
      .eq('post_id', postId)
      .maybeSingle();
    const alreadyReviewed = !!existing;
    const reviewId = (existing?.id as string | null) ?? null;

    // Did this job ever have a dispute? (tags the review + drives the active check)
    const { data: disputes } = await this.supabase.client
      .from('disputes')
      .select('status')
      .eq('post_id', postId);
    const disputeRows = (disputes ?? []) as Array<{ status: string }>;
    const fromDisputedJob = disputeRows.length > 0;
    const hasActiveDispute = disputeRows.some((d) => !TERMINAL_DISPUTE.includes(d.status));

    const base = { alreadyReviewed, reviewId, providerId, fromDisputedJob };

    // ── Gate ──────────────────────────────────────────────────────────────────
    if (userId !== authorId) return { ...deny('Only the client can review this job.'), ...base };
    if (!providerId) return { ...deny('No provider was selected for this job.'), ...base };
    if (providerId === userId) return { ...deny('You cannot review your own job.'), ...base };
    if (alreadyReviewed) return { ...deny('You have already reviewed this job.'), ...base };

    // Approved completion?
    const { data: completion } = await this.supabase.client
      .from('job_completions')
      .select('id')
      .eq('post_id', postId)
      .eq('status', 'approved')
      .maybeSingle();
    if (!completion) return { ...deny('This job has not been completed and approved yet.'), ...base };

    // Paid?
    const { data: paidTx } = await this.supabase.client
      .from('transactions')
      .select('id')
      .eq('post_id', postId)
      .in('status', ['paid', 'payout_pending', 'released'])
      .limit(1)
      .maybeSingle();
    if (!paidTx) return { ...deny('Payment for this job is not complete.'), ...base };

    if (post.status !== 'completed') return { ...deny('This job is not completed yet.'), ...base };
    if (hasActiveDispute) return { ...deny('Resolve the open dispute before reviewing.'), ...base };

    return {
      canReview: true,
      alreadyReviewed: false,
      reviewId: null,
      providerId,
      fromDisputedJob,
      reason: null,
    };
  }
}
