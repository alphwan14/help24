import {
  Controller,
  Get,
  GoneException,
  Param,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { AdminService } from './admin.service';
import { AdminAuthGuard } from './auth/admin-auth.guard';
import { Roles } from './auth/roles.decorator';

/**
 * LEGACY admin surface — retained read-only and now behind the RBAC guard.
 *
 * The arbitration system (DisputesController at /disputes/*) is the single
 * source of truth. The old unauthenticated resolve path is DEPRECATED and
 * returns 410 Gone; all rulings must go through POST /disputes/:id/decision so
 * they are RBAC-checked, case-locked, and written to the immutable ledger.
 */
@Controller('admin')
@UseGuards(AdminAuthGuard)
export class AdminController {
  constructor(private readonly admin: AdminService) {}

  /** @deprecated Use GET /disputes/open. */
  @Get('disputes')
  @Roles('support_agent')
  listDisputes(@Query('status') status?: string) {
    return this.admin.listDisputes(status);
  }

  /** @deprecated Use GET /disputes/:id. */
  @Get('disputes/:id')
  @Roles('support_agent')
  getDispute(@Param('id') id: string) {
    return this.admin.getDispute(id);
  }

  /**
   * @deprecated Removed. Use POST /disputes/:id/decision.
   * Kept as a tombstone so stale clients get a clear, actionable error instead
   * of silently bypassing RBAC + the immutable decision ledger.
   */
  @Post('disputes/resolve')
  resolveDispute(): never {
    throw new GoneException(
      'POST /admin/disputes/resolve is removed. Use POST /disputes/:id/decision ' +
        '(bearer token, RBAC, immutable audit).',
    );
  }
}
