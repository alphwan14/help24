import { Body, Controller, Get, HttpCode, HttpStatus, Post, Put, UseGuards } from '@nestjs/common';
import { AdminAuth } from '../../common/auth/auth.decorator';
import { RateLimit } from '../../common/rate-limit/rate-limit.decorator';
import { AdminAuthGuard } from '../auth/admin-auth.guard';
import { AdminContext } from '../auth/admin-role';
import { CurrentAdmin, Roles } from '../auth/roles.decorator';
import { AdminAlertEmailsService } from './admin-alert-emails.service';
import { AlertEmailSettingsDto } from './dto/alert-email-settings.dto';

/**
 * /admin/alert-emails: the signed-in admin's OWN alert email setting. Every
 * route acts on the admin behind the token and nobody else; there is no id
 * in any path.
 */
@Controller('admin/alert-emails')
@UseGuards(AdminAuthGuard)
@RateLimit('admin:api')
@AdminAuth()
export class AdminAlertEmailsController {
  constructor(private readonly emails: AdminAlertEmailsService) {}

  @Get()
  @Roles('support_agent')
  get(@CurrentAdmin() admin: AdminContext) {
    return this.emails.settingsFor(admin);
  }

  @Put()
  @Roles('support_agent')
  save(@CurrentAdmin() admin: AdminContext, @Body() dto: AlertEmailSettingsDto) {
    return this.emails.saveSettings(admin, dto);
  }

  /** A sample alert to the admin's own address. */
  @Post('test')
  @Roles('support_agent')
  @RateLimit('admin:alert-email-test')
  @HttpCode(HttpStatus.OK)
  test(@CurrentAdmin() admin: AdminContext) {
    return this.emails.sendTest(admin);
  }
}
