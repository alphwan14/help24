import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  ParseUUIDPipe,
  Patch,
  Post,
  UseGuards,
} from '@nestjs/common';
import { AdminAuthGuard } from './auth/admin-auth.guard';
import { CurrentAdmin, Roles } from './auth/roles.decorator';
import { AdminContext } from './auth/admin-role';
import { AdminAuthService } from './auth/admin-auth.service';
import { AdminInvitesService } from './auth/admin-invites.service';
import { CreateAdminDto } from './disputes/dto/admin-user.dto';
import {
  CreateInviteDto,
  UpdateAdminRoleDto,
} from './disputes/dto/admin-invite.dto';

/**
 * Admin identity & invite management. All routes require a valid admin token;
 * privileged routes additionally require super_admin via @Roles. Creating an
 * admin (directly or via invite acceptance) returns a bearer token EXACTLY
 * ONCE — only its hash is stored, so it can never be retrieved later.
 */
@Controller('admin')
@UseGuards(AdminAuthGuard)
export class AdminUsersController {
  constructor(
    private readonly auth: AdminAuthService,
    private readonly invites: AdminInvitesService,
  ) {}

  /**
   * Identity of the caller's bearer token. Any valid admin (no @Roles).
   * The dashboard calls this to validate a token and render role-based UI.
   */
  @Get('me')
  me(@CurrentAdmin() admin: AdminContext) {
    return admin;
  }

  // ── Invites (super_admin) ──────────────────────────────────────────────────

  @Post('invite')
  @Roles('super_admin')
  @HttpCode(HttpStatus.CREATED)
  async invite(
    @Body() dto: CreateInviteDto,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.invites.createInvite({
      email: dto.email,
      role: dto.role,
      createdBy: admin.id,
    });
  }

  @Get('invites')
  @Roles('super_admin')
  listInvites() {
    return this.invites.listPending();
  }

  @Delete('invites/:id')
  @Roles('super_admin')
  revokeInvite(@Param('id', new ParseUUIDPipe()) id: string) {
    return this.invites.revokeInvite(id);
  }

  // ── Admin users management (super_admin) ────────────────────────────────────

  @Get('users')
  @Roles('super_admin')
  listUsers() {
    return this.auth.listAdmins();
  }

  @Patch('users/:id/role')
  @Roles('super_admin')
  updateRole(
    @Param('id', new ParseUUIDPipe()) id: string,
    @Body() dto: UpdateAdminRoleDto,
  ) {
    return this.auth.updateRole(id, dto.role);
  }

  @Delete('users/:id')
  @Roles('super_admin')
  deactivate(
    @Param('id', new ParseUUIDPipe()) id: string,
    @CurrentAdmin() admin: AdminContext,
  ) {
    return this.auth.deactivateAdmin(id, admin.id);
  }

  // ── Legacy direct creation (kept for bootstrap / back-compat) ───────────────

  @Post('admins')
  @Roles('super_admin')
  @HttpCode(HttpStatus.CREATED)
  async create(@Body() dto: CreateAdminDto) {
    const result = await this.auth.createAdmin(dto);
    return {
      ...result,
      notice:
        'Store this token now — it is shown only once and cannot be recovered.',
    };
  }

  @Get('admins')
  @Roles('super_admin')
  list() {
    return this.auth.listAdmins();
  }
}
