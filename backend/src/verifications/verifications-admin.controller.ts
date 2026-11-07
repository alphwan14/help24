import { Body, Controller, Get, Param, ParseUUIDPipe, Post, Query, UseGuards } from '@nestjs/common';
import { AdminAuthGuard } from '../admin/auth/admin-auth.guard';
import { CurrentAdmin, Roles } from '../admin/auth/roles.decorator';
import { AdminContext } from '../admin/auth/admin-role';
import { AdminAuth } from '../common/auth/auth.decorator';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { ListVerificationsQueryDto, ReviewVerificationDto } from './dto/verifications-admin.dto';
import { VerificationsService } from './verifications.service';

/**
 * Provider verification review (migration 135). Any active admin may review:
 * checking an ID against a selfie is support work, and every decision is
 * recorded with the reviewer's id.
 *
 * Under /admin so the boot-time route audit holds it to the admin rules.
 */
@Controller('admin/verifications')
@UseGuards(AdminAuthGuard)
@RateLimit('admin:api')
@AdminAuth()
export class VerificationsAdminController {
  constructor(private readonly verifications: VerificationsService) {}

  @Get('meta')
  @Roles('support_agent')
  meta() {
    return this.verifications.meta();
  }

  @Get('summary')
  @Roles('support_agent')
  summary() {
    return this.verifications.summary();
  }

  @Get()
  @Roles('support_agent')
  list(@Query() query: ListVerificationsQueryDto) {
    return this.verifications.list(query.status ?? 'pending');
  }

  @Get(':id')
  @Roles('support_agent')
  get(@Param('id', ParseUUIDPipe) id: string) {
    return this.verifications.get(id);
  }

  @Post(':id/review')
  @Roles('support_agent')
  review(
    @Param('id', ParseUUIDPipe) id: string,
    @Body() dto: ReviewVerificationDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.verifications.review(id, dto, admin);
  }
}
