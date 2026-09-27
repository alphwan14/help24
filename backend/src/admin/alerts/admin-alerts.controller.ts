import { BadRequestException, Body, Controller, Get, HttpCode, HttpStatus, Param, Post, UseGuards } from '@nestjs/common';
import { AdminAuthGuard } from '../auth/admin-auth.guard';
import { CurrentAdmin, Roles } from '../auth/roles.decorator';
import { AdminContext } from '../auth/admin-role';
import { AdminAuth } from '../../common/auth/auth.decorator';
import { RateLimit } from '../../common/rate-limit/rate-limit.decorator';
import { AdminAlertsService } from './admin-alerts.service';
import { AlertReviewDto } from './dto/alert-review.dto';

/**
 * GET /admin/alerts — what needs an admin's attention right now, derived from
 * live records (see alert-rules.ts for the catalogue and why each one earns a
 * place). Every admin role may read it and review it.
 */
@Controller('admin/alerts')
@UseGuards(AdminAuthGuard)
@RateLimit('admin:api')
@AdminAuth()
export class AdminAlertsController {
  constructor(private readonly alerts: AdminAlertsService) {}

  @Get()
  @Roles('support_agent')
  list() {
    return this.alerts.list();
  }

  /**
   * Mark an alert reviewed — for every admin, for exactly the records it names
   * now — or reopen it. Appended to admin_alert_reviews (migration 117).
   */
  @Post(':alertId/reviews')
  @Roles('support_agent')
  @HttpCode(HttpStatus.CREATED)
  review(@Param('alertId') alertId: string, @Body() dto: AlertReviewDto, @CurrentAdmin() admin: AdminContext) {
    if (!/^[a-z][a-z_]{2,39}$/.test(alertId)) throw new BadRequestException('Unknown alert.');
    return this.alerts.review(admin, alertId, dto);
  }
}
