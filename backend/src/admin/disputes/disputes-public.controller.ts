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
import { RateLimit } from '../../common/rate-limit/rate-limit.decorator';
import { Auth } from '../../common/auth/auth.decorator';

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

  @RateLimit('disputes:create')
  @Post('create')
  @HttpCode(HttpStatus.CREATED)
  // Raising a dispute freezes an escrow transaction and starts an SLA clock
  // that pages a human. `assertParticipant` already requires the raiser to be
  // the post's client or selected provider — binding is what stops a stranger
  // naming one of them and freezing a payment they have nothing to do with.
  @Auth('body.raised_by_user_id')
  create(@Body() dto: CreateDisputeDto) {
    return this.disputes.createDispute(dto);
  }

  // ── Participant case view + thread ──────────────────────────────────────────

  /** Participant case view: metadata, status, public thread, signed evidence. */
  @RateLimit('disputes:participate')
  @Get(':id/thread')
  // The case file: both parties' statements, the payment history and signed
  // URLs into the private evidence bucket. Whoever this field names is who the
  // service serves the case as.
  @Auth('query.user_id')
  thread(
    @Param('id', ParseUUIDPipe) id: string,
    @Query('user_id') userId: string,
  ) {
    return this.disputes.getParticipantThread(id, userId);
  }

  /** Participant posts a text message to the dispute thread. */
  @RateLimit('disputes:participate')
  @Post(':id/reply')
  @HttpCode(HttpStatus.CREATED)
  // Messages here are read by an arbitrator deciding where escrowed money goes,
  // so authorship is evidence in its own right.
  @Auth('body.user_id')
  reply(@Param('id', ParseUUIDPipe) id: string, @Body() dto: ParticipantReplyDto) {
    return this.disputes.participantReply(id, dto);
  }

  // ── Evidence (private bucket, signed URLs only) ─────────────────────────────

  /** Request signed upload URLs for evidence files. */
  @RateLimit('uploads:sign')
  @Post(':id/evidence/upload-url')
  @HttpCode(HttpStatus.OK)
  // Hands out a WRITE CAPABILITY into the private evidence bucket that outlives
  // the request — the strongest reason on this controller to know who is asking.
  @Auth('body.user_id')
  uploadUrl(@Param('id', ParseUUIDPipe) id: string, @Body() dto: RequestUploadUrlsDto) {
    return this.disputes.issueUploadUrls(id, dto);
  }

  /** Register uploaded objects as evidence on the case. */
  @RateLimit('disputes:participate')
  @Post(':id/evidence/submit')
  @HttpCode(HttpStatus.CREATED)
  @Auth('body.user_id')
  submitEvidence(@Param('id', ParseUUIDPipe) id: string, @Body() dto: SubmitEvidenceDto) {
    return this.disputes.submitEvidence(id, dto);
  }
}
