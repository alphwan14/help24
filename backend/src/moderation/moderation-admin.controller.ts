import {
  BadRequestException,
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
import { AdminAuthGuard } from '../admin/auth/admin-auth.guard';
import { CurrentAdmin, Roles } from '../admin/auth/roles.decorator';
import { AdminContext } from '../admin/auth/admin-role';
import { AdminAuth } from '../common/auth/auth.decorator';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import {
  AuditQueryDto,
  ContentActionDto,
  LiftRestrictionDto,
  ListReportsQueryDto,
  NoteDto,
  ResolveReportDto,
  RestrictedQueryDto,
  SanctionDto,
  TriageReportDto,
  USER_ID_PATTERN,
} from './dto/moderation-admin.dto';
import { InvestigationService } from './investigation.service';
import { ModerationService } from './moderation.service';

/**
 * The Trust & Safety console's API. Every route requires a valid admin bearer
 * token (AdminAuthGuard) and at least `support_agent`; the service raises the
 * bar per action (a ban needs super_admin — see SANCTION_MIN_ROLE).
 *
 * Under /admin so the boot-time route audit holds it to the admin rules, and so
 * IdentityMiddleware never tries to read the admin token as a Firebase token.
 */
@Controller('admin/moderation')
@UseGuards(AdminAuthGuard)
@RateLimit('admin:api')
@AdminAuth()
export class ModerationAdminController {
  constructor(
    private readonly investigation: InvestigationService,
    private readonly moderation: ModerationService,
  ) {}

  // ── Overview ───────────────────────────────────────────────────────────────

  @Get('summary')
  @Roles('support_agent')
  summary(@CurrentAdmin() admin: AdminContext) {
    return this.investigation.summary(admin);
  }

  @Get('admins')
  @Roles('support_agent')
  admins() {
    return this.investigation.listAdmins();
  }

  // ── Reports ────────────────────────────────────────────────────────────────

  @Get('reports')
  @Roles('support_agent')
  listReports(@Query() query: ListReportsQueryDto, @CurrentAdmin() admin: AdminContext) {
    return this.investigation.listReports(query, admin);
  }

  @Get('reports/:id')
  @Roles('support_agent')
  getReport(@Param('id', ParseUUIDPipe) id: string) {
    return this.investigation.getReport(id);
  }

  @Post('reports/:id/triage')
  @Roles('support_agent')
  @HttpCode(HttpStatus.OK)
  triage(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: TriageReportDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.moderation.triageReport(admin, id, dto);
  }

  @Post('reports/:id/resolve')
  @Roles('support_agent')
  @HttpCode(HttpStatus.OK)
  resolve(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: ResolveReportDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.moderation.resolveReport(admin, id, dto);
  }

  @Post('reports/:id/notes')
  @Roles('support_agent')
  @HttpCode(HttpStatus.CREATED)
  noteOnReport(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: NoteDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.moderation.addNote(admin, { reportId: id }, dto.note);
  }

  // ── Accounts ───────────────────────────────────────────────────────────────

  @Get('users/:userId')
  @Roles('support_agent')
  getUser(@Param('userId') userId: string) {
    return this.investigation.getUserProfile(validUserId(userId));
  }

  /** Warn, suspend, ban, or restrict messaging/marketplace. Role checked per kind. */
  @Post('users/:userId/sanctions')
  @Roles('support_agent')
  @HttpCode(HttpStatus.CREATED)
  sanction(
    @Param('userId') userId: string,
    @Body() dto: SanctionDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.moderation.applySanction(admin, validUserId(userId), dto);
  }

  @Post('users/:userId/notes')
  @Roles('support_agent')
  @HttpCode(HttpStatus.CREATED)
  noteOnUser(
    @Param('userId') userId: string,
    @Body() dto: NoteDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.moderation.addNote(admin, { userId: validUserId(userId) }, dto.note);
  }

  /** End a sanction early. senior_admin at least; a ban needs super_admin. */
  @Post('restrictions/:id/lift')
  @Roles('senior_admin')
  @HttpCode(HttpStatus.OK)
  lift(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: LiftRestrictionDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.moderation.liftRestriction(admin, id, dto);
  }

  @Get('restricted')
  @Roles('support_agent')
  restricted(@Query() query: RestrictedQueryDto) {
    return this.investigation.listRestricted(query);
  }

  // ── Content ────────────────────────────────────────────────────────────────

  @Post('content/:type/:id/remove')
  @Roles('support_agent')
  @HttpCode(HttpStatus.OK)
  removeContent(
    @Param('type') type: string,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: ContentActionDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.moderation.setContentState(admin, contentType(type), id, 'remove', dto);
  }

  @Post('content/:type/:id/restore')
  @Roles('support_agent')
  @HttpCode(HttpStatus.OK)
  restoreContent(
    @Param('type') type: string,
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: ContentActionDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.moderation.setContentState(admin, contentType(type), id, 'restore', dto);
  }

  // ── Audit ──────────────────────────────────────────────────────────────────

  @Get('audit')
  @Roles('support_agent')
  audit(@Query() query: AuditQueryDto) {
    return this.investigation.listAudit(query);
  }

  /** Recompute the ledger's hash chain. */
  @Get('audit/integrity')
  @Roles('senior_admin')
  integrity() {
    return this.investigation.integrity();
  }
}

function validUserId(id: string): string {
  if (!USER_ID_PATTERN.test(id ?? '')) {
    throw new BadRequestException({ code: 'MODERATION_INVALID', message: 'That is not an account id.' });
  }
  return id;
}

function contentType(type: string): 'post' | 'message' {
  if (type !== 'post' && type !== 'message') {
    throw new BadRequestException({ code: 'MODERATION_INVALID', message: 'Content type must be post or message.' });
  }
  return type;
}
