import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  ParseUUIDPipe,
  Post,
  Query,
} from '@nestjs/common';
import { DisputesService } from './disputes.service';
import { CreateDisputeDto } from './dto/create-dispute.dto';
import {
  ParticipantReplyDto,
  RequestUploadUrlsDto,
  SubmitEvidenceDto,
} from './dto/participant.dto';

/**
 * User-facing dispute API. Deliberately NOT behind the admin guard — the actor
 * is a client/provider (Firebase user) identified by user_id and validated
 * against the post's participants inside the service (assertParticipant).
 *
 * ROUTE DISCIPLINE: the admin controller (AdminAuthGuard) already owns
 * GET /disputes/:id, POST /disputes/:id/message and POST /disputes/:id/evidence.
 * Every participant route below uses a DISTINCT sub-path (/thread, /reply,
 * /evidence/upload-url, /evidence/submit) so the two controllers never collide
 * and an unauthenticated request can never reach an admin handler.
 */
@Controller('disputes')
export class DisputesPublicController {
  constructor(private readonly disputes: DisputesService) {}

  // ── Create (client or provider raises a dispute) ────────────────────────────

  @Post('create')
  @HttpCode(HttpStatus.CREATED)
  create(@Body() dto: CreateDisputeDto) {
    return this.disputes.createDispute(dto);
  }

  // ── Participant case view + thread ──────────────────────────────────────────

  /** Participant case view: metadata, status, public thread, signed evidence. */
  @Get(':id/thread')
  thread(
    @Param('id', ParseUUIDPipe) id: string,
    @Query('user_id') userId: string,
  ) {
    return this.disputes.getParticipantThread(id, userId);
  }

  /** Participant posts a text message to the dispute thread. */
  @Post(':id/reply')
  @HttpCode(HttpStatus.CREATED)
  reply(@Param('id', ParseUUIDPipe) id: string, @Body() dto: ParticipantReplyDto) {
    return this.disputes.participantReply(id, dto);
  }

  // ── Evidence (private bucket, signed URLs only) ─────────────────────────────

  /** Request signed upload URLs for evidence files. */
  @Post(':id/evidence/upload-url')
  @HttpCode(HttpStatus.OK)
  uploadUrl(@Param('id', ParseUUIDPipe) id: string, @Body() dto: RequestUploadUrlsDto) {
    return this.disputes.issueUploadUrls(id, dto);
  }

  /** Register uploaded objects as evidence on the case. */
  @Post(':id/evidence/submit')
  @HttpCode(HttpStatus.CREATED)
  submitEvidence(@Param('id', ParseUUIDPipe) id: string, @Body() dto: SubmitEvidenceDto) {
    return this.disputes.submitEvidence(id, dto);
  }
}
