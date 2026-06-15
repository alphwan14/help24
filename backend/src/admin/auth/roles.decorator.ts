import {
  SetMetadata,
  createParamDecorator,
  ExecutionContext,
} from '@nestjs/common';
import { AdminContext, AdminRole } from './admin-role';

/** Metadata key holding the MINIMUM role required for a route. */
export const ROLES_KEY = 'admin_min_role';

/**
 * Declares the minimum admin role required to call a route.
 * Hierarchical: @Roles('senior_admin') also admits super_admin.
 *
 *   @Roles('senior_admin')
 *   @Post(':id/decision')
 */
export const Roles = (minRole: AdminRole) => SetMetadata(ROLES_KEY, minRole);

/**
 * Injects the authenticated admin (attached by AdminAuthGuard) into a handler.
 *
 *   resolve(@CurrentAdmin() admin: AdminContext) { ... }
 */
export const CurrentAdmin = createParamDecorator(
  (_data: unknown, ctx: ExecutionContext): AdminContext => {
    const req = ctx.switchToHttp().getRequest<{ admin?: AdminContext }>();
    return req.admin as AdminContext;
  },
);
