import { Body, Controller, Get, Param, Post, Query } from '@nestjs/common';
import { AdminService } from './admin.service';
import { ResolveDisputeDto } from './dto/resolve-dispute.dto';

@Controller('admin')
export class AdminController {
  constructor(private readonly admin: AdminService) {}

  /** List all disputes, optionally filtered by status. */
  @Get('disputes')
  listDisputes(@Query('status') status?: string) {
    return this.admin.listDisputes(status);
  }

  /** Get full dispute detail including buyer, provider, timeline. */
  @Get('disputes/:id')
  getDispute(@Param('id') id: string) {
    return this.admin.getDispute(id);
  }

  /** Resolve a dispute: release_full | refund_full | partial_split. */
  @Post('disputes/resolve')
  resolveDispute(@Body() dto: ResolveDisputeDto) {
    return this.admin.resolveDispute(dto);
  }
}
