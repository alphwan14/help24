import { Body, Controller, Get, HttpCode, HttpStatus, Param, ParseUUIDPipe, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { AdminAuthGuard } from '../admin/auth/admin-auth.guard';
import { CurrentAdmin, Roles } from '../admin/auth/roles.decorator';
import { AdminContext } from '../admin/auth/admin-role';
import { AdminAuth } from '../common/auth/auth.decorator';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { SupportService } from './support.service';
import { ListConversationsQueryDto, StartConversationDto, SupportStatusDto, SupportTextDto } from './dto/support.dto';

/**
 * The dashboard's Inbox (migration 138). Every admin role works it: answering
 * members is support work. The member always sees "Help24 Support"; which
 * admin wrote what is recorded for the team only.
 */
@Controller('admin/support')
@UseGuards(AdminAuthGuard)
@RateLimit('admin:api')
@AdminAuth()
export class SupportAdminController {
  constructor(private readonly support: SupportService) {}

  @Get('conversations')
  @Roles('support_agent')
  list(@Query() query: ListConversationsQueryDto) {
    return this.support.list(query);
  }

  @Post('conversations')
  @Roles('support_agent')
  @HttpCode(HttpStatus.CREATED)
  start(@Body() dto: StartConversationDto, @CurrentAdmin() admin: AdminContext) {
    return this.support.start(admin, dto);
  }

  @Get('conversations/:id')
  @Roles('support_agent')
  get(@Param('id', new ParseUUIDPipe()) id: string) {
    return this.support.get(id);
  }

  @Post('conversations/:id/replies')
  @Roles('support_agent')
  @HttpCode(HttpStatus.CREATED)
  reply(@Param('id', new ParseUUIDPipe()) id: string, @Body() dto: SupportTextDto, @CurrentAdmin() admin: AdminContext) {
    return this.support.reply(id, admin, dto.body);
  }

  @Post('conversations/:id/messages/:messageId/retry')
  @Roles('support_agent')
  @HttpCode(HttpStatus.OK)
  retry(@Param('id', new ParseUUIDPipe()) id: string, @Param('messageId', new ParseUUIDPipe()) messageId: string) {
    return this.support.retry(id, messageId);
  }

  @Post('conversations/:id/notes')
  @Roles('support_agent')
  @HttpCode(HttpStatus.CREATED)
  note(@Param('id', new ParseUUIDPipe()) id: string, @Body() dto: SupportTextDto, @CurrentAdmin() admin: AdminContext) {
    return this.support.note(id, admin, dto.body);
  }

  @Patch('conversations/:id')
  @Roles('support_agent')
  setStatus(@Param('id', new ParseUUIDPipe()) id: string, @Body() dto: SupportStatusDto) {
    return this.support.setStatus(id, dto.status);
  }
}
