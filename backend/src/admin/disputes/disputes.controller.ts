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
  UseGuards,
} from '@nestjs/common';
import { AdminAuthGuard } from '../auth/admin-auth.guard';
import { CurrentAdmin, Roles } from '../auth/roles.decorator';
import { AdminContext } from '../auth/admin-role';
import { DisputesService } from './disputes.service';
import { DecisionsService } from './decisions.service';
import { DisputeRecommendationService } from './recommendation.service';
import { DecisionDto } from './dto/decision.dto';
import { AddEvidenceDto } from './dto/evidence.dto';
import { PostMessageDto } from './dto/message.dto';

/**
 * Admin Disputes Centre. Every route requires a valid admin bearer token
 * (AdminAuthGuard); individual routes raise the bar with @Roles(...).
 *
 * Base path /disputes. Static segments are declared before ':id' so e.g.
 * GET /disputes/open is not captured by GET /disputes/:id.
 */
@Controller('disputes')
@UseGuards(AdminAuthGuard)
export class DisputesController {
  constructor(
    private readonly disputes: DisputesService,
    private readonly decisions: DecisionsService,
    private readonly recommendation: DisputeRecommendationService,
  ) {}

  // ── Queues ────────────────────────────────────────────────────────────────

  @Get('open')
  @Roles('support_agent')
  listOpen(@Query('status') status?: string) {
    return this.disputes.listOpen(status);
  }

  // ── Case detail + advisory ──────────────────────────────────────────────────

  @Get(':id')
  @Roles('support_agent')
  getCase(@Param('id', ParseUUIDPipe) id: string) {
    return this.disputes.getCase(id);
  }

  @Get(':id/recommendation')
  @Roles('support_agent')
  recommend(@Param('id', ParseUUIDPipe) id: string) {
    return this.recommendation.analyze(id);
  }

  // ── Assignment (case lock) ──────────────────────────────────────────────────

  @Post(':id/assign')
  @Roles('support_agent')
  @HttpCode(HttpStatus.OK)
  assign(@Param('id', ParseUUIDPipe) id: string, @CurrentAdmin() admin: AdminContext) {
    return this.disputes.assign(id, admin);
  }

  // ── Evidence ────────────────────────────────────────────────────────────────

  @Post(':id/evidence')
  @Roles('support_agent')
  @HttpCode(HttpStatus.CREATED)
  addEvidence(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: AddEvidenceDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.disputes.addEvidence(id, dto, admin);
  }

  @Get(':id/evidence')
  @Roles('support_agent')
  listEvidence(@Param('id', ParseUUIDPipe) id: string) {
    return this.disputes.listEvidence(id);
  }

  // ── Court thread ────────────────────────────────────────────────────────────

  @Post(':id/message')
  @Roles('support_agent')
  @HttpCode(HttpStatus.CREATED)
  postMessage(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: PostMessageDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.disputes.postMessage(id, dto.message, admin);
  }

  @Get(':id/messages')
  @Roles('support_agent')
  listMessages(@Param('id', ParseUUIDPipe) id: string) {
    return this.disputes.listMessages(id);
  }

  // ── Decisions (immutable ledger) ────────────────────────────────────────────

  @Get(':id/decisions')
  @Roles('support_agent')
  listDecisions(@Param('id', ParseUUIDPipe) id: string) {
    return this.disputes.listDecisions(id);
  }

  /**
   * Issue a binding ruling. Controller admits any admin (so ESCALATE is open);
   * DecisionsService enforces senior_admin+ for the financial decision types and
   * the case-lock / override rules.
   */
  @Post(':id/decision')
  @Roles('support_agent')
  @HttpCode(HttpStatus.OK)
  decide(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: DecisionDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.decisions.decide(id, dto, admin);
  }

  /** Alias for issuing a ruling (spec parity). Financial-only entry point. */
  @Post(':id/resolve')
  @Roles('senior_admin')
  @HttpCode(HttpStatus.OK)
  resolve(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: DecisionDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.decisions.decide(id, dto, admin);
  }
}
