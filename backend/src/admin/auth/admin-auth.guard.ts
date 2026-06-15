import {
  CanActivate,
  ExecutionContext,
  ForbiddenException,
  Injectable,
  Logger,
  UnauthorizedException,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { AdminAuthService } from './admin-auth.service';
import { ROLES_KEY } from './roles.decorator';
import { AdminContext, AdminRole, roleAtLeast } from './admin-role';

/**
 * Single guard that does BOTH authentication and authorization for admin routes:
 *
 *  1. Reads `Authorization: Bearer <token>`, resolves it to an admin, and
 *     attaches the AdminContext to `request.admin`.
 *  2. If the route declares @Roles(minRole), enforces the role hierarchy.
 *     Routes with no @Roles still require a valid admin (authentication only).
 *
 * Apply at controller level with @UseGuards(AdminAuthGuard).
 */
@Injectable()
export class AdminAuthGuard implements CanActivate {
  private readonly logger = new Logger(AdminAuthGuard.name);

  constructor(
    private readonly auth: AdminAuthService,
    private readonly reflector: Reflector,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const req = context
      .switchToHttp()
      .getRequest<{ headers: Record<string, string | undefined>; admin?: AdminContext }>();

    const header = req.headers['authorization'] ?? req.headers['Authorization'];
    if (!header || !header.startsWith('Bearer ')) {
      throw new UnauthorizedException('Missing admin bearer token.');
    }

    const token = header.slice(7).trim();
    if (!token) throw new UnauthorizedException('Empty admin bearer token.');

    const admin = await this.auth.resolveToken(token);
    if (!admin) throw new UnauthorizedException('Invalid or inactive admin token.');

    req.admin = admin;

    // Authorization: enforce minimum role if the route declares one.
    const minRole = this.reflector.getAllAndOverride<AdminRole | undefined>(ROLES_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);

    if (minRole && !roleAtLeast(admin.role, minRole)) {
      this.logger.warn(
        `[ADMIN_AUTH] ${admin.email} (role=${admin.role}) denied — needs ${minRole}`,
      );
      throw new ForbiddenException(`Requires role '${minRole}' or higher.`);
    }

    return true;
  }
}
