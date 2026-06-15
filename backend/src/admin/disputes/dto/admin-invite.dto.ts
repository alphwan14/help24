import {
  IsEmail,
  IsIn,
  IsString,
  MaxLength,
  MinLength,
} from 'class-validator';
import { ADMIN_ROLES, AdminRole } from '../../auth/admin-role';

/** Issue an invite (super_admin only). */
export class CreateInviteDto {
  @IsEmail()
  email: string;

  @IsIn(ADMIN_ROLES as unknown as string[])
  role: AdminRole;
}

/** Accept an invite (public — the invite token is the authorization). */
export class AcceptInviteDto {
  @IsString()
  @MinLength(10)
  token: string;

  @IsString()
  @MinLength(2)
  @MaxLength(120)
  name: string;

  @IsString()
  @MinLength(8)
  @MaxLength(200)
  password: string;
}

/** Change an admin's role (super_admin only). */
export class UpdateAdminRoleDto {
  @IsIn(ADMIN_ROLES as unknown as string[])
  role: AdminRole;
}

/**
 * Restore arbitration access from an authenticated Supabase session. The
 * accessToken is the Supabase JWT; the backend verifies it independently, so
 * no admin bearer token is involved (this is how a fresh login auto-reconnects).
 */
export class RestoreSessionDto {
  @IsString()
  @MinLength(20)
  accessToken: string;
}
