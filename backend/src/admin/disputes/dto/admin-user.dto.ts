import { IsEmail, IsIn, IsString, MaxLength } from 'class-validator';
import { ADMIN_ROLES, AdminRole } from '../../auth/admin-role';

/** Create a new admin (super_admin only). Returns a one-time bearer token. */
export class CreateAdminDto {
  @IsEmail()
  email: string;

  @IsString()
  @MaxLength(120)
  name: string;

  @IsIn(ADMIN_ROLES as unknown as string[])
  role: AdminRole;
}
