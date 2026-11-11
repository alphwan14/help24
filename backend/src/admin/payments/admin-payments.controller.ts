import { Body, Controller, Get, HttpCode, HttpStatus, Param, ParseUUIDPipe, Post, UseGuards } from '@nestjs/common';
import { AdminAuth } from '../../common/auth/auth.decorator';
import { RateLimit } from '../../common/rate-limit/rate-limit.decorator';
import { AdminAuthGuard } from '../auth/admin-auth.guard';
import { AdminContext } from '../auth/admin-role';
import { CurrentAdmin, Roles } from '../auth/roles.decorator';
import { AdminPaymentsService } from './admin-payments.service';
import { AdminOpenDisputeDto, AdminReasonDto } from './dto/admin-payments.dto';

/**
 * /admin/transactions/:id — one payment with its whole story, and the actions
 * an admin can take on it (the dashboard's transaction page). Reading is open
 * to every admin; moving money or a job's state needs a senior admin; opening
 * a dispute (which freezes money and moves none) is open to every admin. The
 * service checks each action against the payment as it stands now, and
 * records who took it and why before it runs.
 */
@Controller('admin/transactions')
@UseGuards(AdminAuthGuard)
@RateLimit('admin:api')
@AdminAuth()
export class AdminPaymentsController {
  constructor(private readonly payments: AdminPaymentsService) {}

  @Get(':id')
  @Roles('support_agent')
  detail(@Param('id', ParseUUIDPipe) id: string, @CurrentAdmin() admin: AdminContext) {
    return this.payments.detail(id, admin);
  }

  @Post(':id/retry-payout')
  @Roles('senior_admin')
  @HttpCode(HttpStatus.OK)
  retryPayout(@Param('id', ParseUUIDPipe) id: string, @Body() dto: AdminReasonDto, @CurrentAdmin() admin: AdminContext) {
    return this.payments.retryPayout(id, admin, dto.reason);
  }

  @Post(':id/check-mpesa')
  @Roles('senior_admin')
  @HttpCode(HttpStatus.OK)
  checkMpesa(@Param('id', ParseUUIDPipe) id: string, @CurrentAdmin() admin: AdminContext) {
    return this.payments.checkMpesa(id, admin);
  }

  @Post(':id/approve-completion')
  @Roles('senior_admin')
  @HttpCode(HttpStatus.OK)
  approveCompletion(@Param('id', ParseUUIDPipe) id: string, @Body() dto: AdminReasonDto, @CurrentAdmin() admin: AdminContext) {
    return this.payments.approveCompletion(id, admin, dto.reason);
  }

  @Post(':id/open-dispute')
  @Roles('support_agent')
  @HttpCode(HttpStatus.CREATED)
  openDispute(@Param('id', ParseUUIDPipe) id: string, @Body() dto: AdminOpenDisputeDto, @CurrentAdmin() admin: AdminContext) {
    return this.payments.openDispute(id, admin, dto.raised_by, dto.reason);
  }

  @Post(':id/cancel-hire')
  @Roles('senior_admin')
  @HttpCode(HttpStatus.OK)
  cancelHire(@Param('id', ParseUUIDPipe) id: string, @Body() dto: AdminReasonDto, @CurrentAdmin() admin: AdminContext) {
    return this.payments.cancelHire(id, admin, dto.reason);
  }
}
