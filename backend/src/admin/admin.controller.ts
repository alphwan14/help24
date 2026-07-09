import {
  BadRequestException,
  Body,
  Controller,
  Get,
  GoneException,
  HttpCode,
  HttpStatus,
  Param,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { AdminService } from './admin.service';
import { MpesaService } from '../mpesa/mpesa.service';
import { AdminAuthGuard } from './auth/admin-auth.guard';
import { Roles, CurrentAdmin } from './auth/roles.decorator';
import { AdminContext } from './auth/admin-role';

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
  constructor(
    private readonly admin: AdminService,
    private readonly mpesa: MpesaService,
  ) {}

  /**
   * Reconcile a stranded payout for a post whose B2C RESULT callback never
   * arrived (transaction/escrow stuck in 'payout_pending'), or repair a
   * split-brain escrow. Settles ONLY on a confirmed result — dev simulates a
   * confirmed success; prod dispatches Daraja's Transaction Status Query and
   * settles asynchronously when Daraja confirms completion. Never releases money
   * on age alone. Requires senior_admin (same bar as financial decisions).
   *
   * POST /admin/reconcile-payout  { "post_id": "..." }
   */
  @Post('reconcile-payout')
  @Roles('senior_admin')
  @HttpCode(HttpStatus.OK)
  reconcilePayout(@Body() body: { post_id?: string }, @CurrentAdmin() admin: AdminContext) {
    if (!body?.post_id) throw new BadRequestException('post_id is required');
    return this.mpesa.reconcilePayout(body.post_id, admin.email);
  }

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
