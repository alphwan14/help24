import { Body, Controller, Get, HttpCode, HttpStatus, Param, ParseUUIDPipe, Post, UseGuards } from '@nestjs/common';
import { AdminAuthGuard } from '../auth/admin-auth.guard';
import { CurrentAdmin, Roles } from '../auth/roles.decorator';
import { AdminContext } from '../auth/admin-role';
import { AdminAuth } from '../../common/auth/auth.decorator';
import { RateLimit } from '../../common/rate-limit/rate-limit.decorator';
import { ApplyRulingDto, ManualSettlementDto } from './dto/finance.dto';
import { FinanceRepairsService } from './finance-repairs.service';

/**
 * Money after a ruling (migration 117). Reading is open to every admin role;
 * both repairs are financial decisions and need a senior admin — the same bar
 * as issuing a ruling in the Disputes centre.
 */
@Controller('admin/finance')
@UseGuards(AdminAuthGuard)
@RateLimit('admin:api')
@AdminAuth()
export class FinanceRepairsController {
  constructor(private readonly finance: FinanceRepairsService) {}

  @Get('disputes/:id/money')
  @Roles('support_agent')
  money(@Param('id', ParseUUIDPipe) id: string) {
    return this.finance.money(id);
  }

  /** Finance paid a ruling's share by hand — record it (amount from the ruling). */
  @Post('transactions/:id/manual-settlements')
  @Roles('senior_admin')
  @HttpCode(HttpStatus.CREATED)
  recordManualSettlement(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: ManualSettlementDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.finance.recordManualSettlement(admin, id, dto);
  }

  /** Apply the ruling on record to money a legacy resolve left frozen. */
  @Post('disputes/:id/apply-ruling')
  @Roles('senior_admin')
  @HttpCode(HttpStatus.OK)
  applyRuling(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: ApplyRulingDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.finance.applyRecordedRuling(admin, id, dto);
  }
}
