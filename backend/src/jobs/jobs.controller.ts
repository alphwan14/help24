import { Body, Controller, Get, GoneException, HttpCode, HttpStatus, Param, Post, Query } from '@nestjs/common';
import { IsString, IsUUID } from 'class-validator';
import { JobsService } from './jobs.service';
import { MarkCompleteDto } from './dto/mark-complete.dto';
import { ApproveDto } from './dto/client-decision.dto';
import { SelectProviderDto } from './dto/select-provider.dto';

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
  notifyApplication(@Body() dto: NotifyApplicationDto) {
    return this.jobs.notifyApplication(dto);
  }

  /** Client selects a provider — assigns them to the post, emits event, notifies provider. */
  @Post('select-provider')
  selectProvider(@Body() dto: SelectProviderDto) {
    return this.jobs.selectProvider(dto);
  }

  /** Provider marks the job as done — creates a completion request. */
  @Post('mark-complete')
  markComplete(@Body() dto: MarkCompleteDto) {
    return this.jobs.markComplete(dto);
  }

  /** Client approves the completion → triggers payout. */
  @Post('approve')
  approve(@Body() dto: ApproveDto) {
    return this.jobs.approve(dto);
  }

  /**
   * DEPRECATED. The legacy dispute-creation path is removed (Sprint 1, Phase 1.5)
   * so the 'disputed' lifecycle state has a single authoritative writer. Disputes
   * are now raised through the arbitration centre: POST /disputes/create.
   */
  @Post('dispute')
  dispute(): never {
    throw new GoneException(
      'POST /jobs/dispute is removed. Update the app — disputes are now raised via POST /disputes/create.',
    );
  }

  /** Get the latest job completion status for a post. */
  @Get(':postId/status')
  getStatus(@Param('postId') postId: string) {
    return this.jobs.getJobStatus(postId);
  }

  /**
   * Participant-scoped job lifecycle aggregate (payment + completion + dispute +
   * timeline) that drives the mobile Job Lifecycle Detail screen. The caller's
   * Firebase UID is passed as ?user_id= and must be the client or selected provider.
   */
  @Get(':postId/lifecycle')
  getLifecycle(@Param('postId') postId: string, @Query('user_id') userId: string) {
    return this.jobs.getLifecycle(postId, userId);
  }
}
