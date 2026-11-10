import { Body, Controller, Get, HttpCode, HttpStatus, Post, Query } from '@nestjs/common';
import { Auth } from '../common/auth/auth.decorator';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { AppSupportMessageDto, AppSupportReadDto, AppUploadUrlsDto } from './dto/support-app.dto';
import { SupportService } from './support.service';

/**
 * Message Help24 (migration 142): a member writes to Help24 from the app and
 * reads the answers. Every route serves the SIGNED-IN member's own thread:
 * the Firebase identity is bound onto `user_id`, so nobody can read or write
 * another member's conversation by naming them.
 */
@Controller('support/app')
export class SupportAppController {
  constructor(private readonly support: SupportService) {}

  /** The member's thread: their messages and Help24's answers, never notes or staff names. */
  @RateLimit('support:app')
  @Get('thread')
  // Whoever this field names is whose support conversation is returned.
  @Auth('query.user_id')
  thread(@Query('user_id') userId: string) {
    return this.support.appThread(userId);
  }

  /** A message to Help24. Opens the member's thread the first time. */
  @RateLimit('support:app')
  @Post('messages')
  @HttpCode(HttpStatus.CREATED)
  // Staff act on what a member tells them here: authorship must be the
  // signed-in member, not a name in the body.
  @Auth('body.user_id')
  send(@Body() dto: AppSupportMessageDto) {
    return this.support.appSend(dto.user_id, dto.body, dto.client_id, dto.attachments ?? []);
  }

  /**
   * Signed upload links for up to 5 photos (migration 143), each under the
   * member's own storage prefix; the message then names the paths.
   */
  @RateLimit('support:app')
  @Post('attachments')
  @HttpCode(HttpStatus.CREATED)
  // The prefix the links are made under is this member's: binding stops one
  // member uploading into another's space.
  @Auth('body.user_id')
  uploadUrls(@Body() dto: AppUploadUrlsDto) {
    return this.support.appUploadUrls(dto.user_id, dto.files);
  }

  /** The member opened their thread: answers so far are read. */
  @RateLimit('support:app')
  @Post('read')
  @HttpCode(HttpStatus.OK)
  @Auth('body.user_id')
  read(@Body() dto: AppSupportReadDto) {
    return this.support.appMarkRead(dto.user_id);
  }
}
