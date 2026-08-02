import { Body, Controller, Get, GoneException, HttpCode, HttpStatus, Param, Post, Query } from '@nestjs/common';
import { IsString, IsUUID } from 'class-validator';
import { JobsService } from './jobs.service';
import { MarkCompleteDto } from './dto/mark-complete.dto';
import { ApproveDto } from './dto/client-decision.dto';
import { SelectProviderDto } from './dto/select-provider.dto';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { Auth, Public } from '../common/auth/auth.decorator';

class NotifyApplicationDto {
  @IsUUID()
  post_id: string;

  @IsString()
  applicant_user_id: string;
}

@Controller('jobs')
export class JobsController {
  constructor(private readonly jobs: JobsService) {}

  /** Called by mobile app after a provider submits an application — notifies the post author. */
  @Post('notify-application')
  @HttpCode(HttpStatus.NO_CONTENT)
  @RateLimit('jobs:action')
  // The caller IS the applicant; the notification goes to the post author.
  // Unbound, this is a push-notification injector: name any applicant and any
  // post, and the author's phone buzzes with an application that never happened.
  @Auth('body.applicant_user_id')
  notifyApplication(@Body() dto: NotifyApplicationDto) {
    return this.jobs.notifyApplication(dto);
  }

  /** Client selects a provider — assigns them to the post, emits event, notifies provider. */
  @Post('select-provider')
  @RateLimit('jobs:action')
  // ⚠️ BIND `client_user_id` ONLY. `provider_id` on this DTO names the person
  // being SELECTED, not the caller — binding it would let anyone assign
  // themselves to any open job, which is an authorization hole created BY the
  // authorization layer. The service checks post.author_user_id ===
  // client_user_id; making that field trustworthy is the whole fix.
  @Auth('body.client_user_id')
  selectProvider(@Body() dto: SelectProviderDto) {
    return this.jobs.selectProvider(dto);
  }

  /** Provider marks the job as done — creates a completion request. */
  @Post('mark-complete')
  @RateLimit('jobs:action')
  // Gates the escrow release request. jobs.service compares this against
  // post.selected_provider_id.
  @Auth('body.provider_user_id')
  markComplete(@Body() dto: MarkCompleteDto) {
    return this.jobs.markComplete(dto);
  }

  /** Client approves the completion → triggers payout. */
  @Post('approve')
  @RateLimit('jobs:action')
  // THE HIGHEST-VALUE BINDING ON THIS API. Approval emits
  // payment.payout_requested, which releases escrowed money to the provider.
  // The service already refuses unless post.author_user_id === client_user_id;
  // until this binding, that field was chosen by the caller.
  @Auth('body.client_user_id')
  approve(@Body() dto: ApproveDto) {
    return this.jobs.approve(dto);
  }

  /**
   * DEPRECATED. The legacy dispute-creation path is removed (Sprint 1, Phase 1.5)
   * so the 'disputed' lifecycle state has a single authoritative writer. Disputes
   * are now raised through the arbitration centre: POST /disputes/create.
   */
  @Post('dispute')
  @RateLimit('jobs:action')
  // Answers 410 unconditionally and touches nothing — there is no state to
  // protect, and requiring a token would only turn a clear "update your app"
  // into a misleading "sign in".
  @Public('Removed endpoint. Answers 410 Gone to every caller and reads no state.')
  dispute(): never {
    throw new GoneException(
      'POST /jobs/dispute is removed. Update the app — disputes are now raised via POST /disputes/create.',
    );
  }

  /** Get the latest job completion status for a post. */
  @Get(':postId/status')
  @RateLimit('jobs:read')
  // No identity field to bind — the handler takes only a post id — but
  // completion state is private to the two parties, so the route still requires
  // a signed-in caller rather than serving it to anyone with a post id.
  // Narrowing further (to the actual participants) needs a service-level change
  // and is called out in the security review rather than smuggled in here.
  @Auth()
  getStatus(@Param('postId') postId: string) {
    return this.jobs.getJobStatus(postId);
  }

  /**
   * Participant-scoped job lifecycle aggregate (payment + completion + dispute +
   * timeline) that drives the mobile Job Lifecycle Detail screen. The caller's
   * Firebase UID is passed as ?user_id= and must be the client or selected provider.
   */
  @Get(':postId/lifecycle')
  @RateLimit('jobs:read')
  // The service already requires this to be the client or selected provider —
  // binding is what stops the caller nominating whichever of the two they
  // please and reading the full payment, completion and dispute history.
  @Auth('query.user_id')
  getLifecycle(@Param('postId') postId: string, @Query('user_id') userId: string) {
    return this.jobs.getLifecycle(postId, userId);
  }

  /**
   * Archive (soft delete) a post. Author-only, policy-enforced: blocked while
   * funds are in escrow or a dispute is active. Never hard-deletes — all history
   * (reviews, reputation, escrow, disputes, chats) is preserved.
   */
  @Post(':postId/archive')
  @RateLimit('jobs:action')
  // Author-only soft delete; the service compares against post.author_user_id.
  @Auth('body.user_id')
  archive(@Param('postId') postId: string, @Body('user_id') userId: string) {
    return this.jobs.archivePost(postId, userId);
  }
}
