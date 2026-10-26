import { BadRequestException, Body, Controller, HttpCode, HttpStatus, Param, Post, UseGuards } from '@nestjs/common';
import { AdminAuthGuard } from '../auth/admin-auth.guard';
import { CurrentAdmin, Roles } from '../auth/roles.decorator';
import { AdminContext } from '../auth/admin-role';
import { AdminAuth } from '../../common/auth/auth.decorator';
import { RateLimit } from '../../common/rate-limit/rate-limit.decorator';
import { RequestRescueService } from './request-rescue.service';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * POST /admin/marketplace/requests/:postId/notify-providers
 *   { providerIds: string[] }  →  { notified, withPush, skipped[] }
 *
 * Any admin may send it: the limits that protect members (once per request,
 * DAILY_CAP a day, never the client/applicants/suspended) are enforced in
 * RequestRescueService for every caller.
 */
@Controller('admin/marketplace/requests')
@UseGuards(AdminAuthGuard)
@RateLimit('admin:api')
@AdminAuth()
export class RequestRescueController {
  constructor(private readonly rescue: RequestRescueService) {}

  @Post(':postId/notify-providers')
  @Roles('support_agent')
  @HttpCode(HttpStatus.OK)
  notify(
    @Param('postId') postId: string,
    @Body() body: { providerIds?: unknown },
    @CurrentAdmin() admin: AdminContext,
  ) {
    if (!UUID.test(postId)) throw new BadRequestException('Unknown listing.');
    if (!Array.isArray(body?.providerIds)) throw new BadRequestException('providerIds must be a list.');
    return this.rescue.notifyProviders(admin, postId, body.providerIds as string[]);
  }
}
