import { Body, Controller, Get, Param, Post } from '@nestjs/common';
import { JobsService } from './jobs.service';
import { MarkCompleteDto } from './dto/mark-complete.dto';
import { ApproveDto, DisputeDto } from './dto/client-decision.dto';

@Controller('jobs')
export class JobsController {
  constructor(private readonly jobs: JobsService) {}

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
