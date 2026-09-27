import { Controller, Get, UseGuards } from '@nestjs/common';
import { AdminAuthGuard } from '../auth/admin-auth.guard';
import { Roles } from '../auth/roles.decorator';
import { AdminAuth } from '../../common/auth/auth.decorator';
import { RateLimit } from '../../common/rate-limit/rate-limit.decorator';
import { AdminAlertsService } from './admin-alerts.service';

/**
 * GET /admin/alerts — what needs an admin's attention right now, derived from
 * live records (see alert-rules.ts for the catalogue and why each one earns a
 * place). Read-only; every admin role may read it.
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
}
