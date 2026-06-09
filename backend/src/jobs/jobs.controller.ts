import { Body, Controller, Get, HttpCode, HttpStatus, Param, Post } from '@nestjs/common';
import { IsString, IsUUID } from 'class-validator';
import { JobsService } from './jobs.service';
import { MarkCompleteDto } from './dto/mark-complete.dto';
import { ApproveDto, DisputeDto } from './dto/client-decision.dto';
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

  /** Client raises a dispute → freezes escrow, creates admin ticket. */
  @Post('dispute')
  dispute(@Body() dto: DisputeDto) {
    return this.jobs.dispute(dto);
  }

  /** Get the latest job completion status for a post. */
  @Get(':postId/status')
  getStatus(@Param('postId') postId: string) {
    return this.jobs.getJobStatus(postId);
  }
}
