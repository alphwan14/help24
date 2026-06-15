import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Post,
  UseGuards,
} from '@nestjs/common';
import { AdminAuthGuard } from './auth/admin-auth.guard';
import { CurrentAdmin, Roles } from './auth/roles.decorator';
import { AdminContext } from './auth/admin-role';
import { AdminAuthService } from './auth/admin-auth.service';
import { CreateAdminDto } from './disputes/dto/admin-user.dto';

/**
 * Admin identity management. super_admin only. Creating an admin returns the
 * bearer token EXACTLY ONCE — it is never stored in plaintext, so it cannot be
 * retrieved later.
 */
@Controller('admin')
@UseGuards(AdminAuthGuard)
export class AdminUsersController {
  constructor(private readonly auth: AdminAuthService) {}

  /**
   * Identity of the caller's bearer token. Any valid admin (no @Roles).
   * The dashboard calls this to validate a token at connect-time and to render
   * the current admin's role for UI gating.
   */
  @Get('me')
  me(@CurrentAdmin() admin: AdminContext) {
    return admin;
  }

  @Post('admins')
  @Roles('super_admin')
  @HttpCode(HttpStatus.CREATED)
  async create(@Body() dto: CreateAdminDto) {
    const result = await this.auth.createAdmin(dto);
    return {
      ...result,
      notice: 'Store this token now — it is shown only once and cannot be recovered.',
    };
  }

  @Get('admins')
  @Roles('super_admin')
  list() {
    return this.auth.listAdmins();
  }
}
