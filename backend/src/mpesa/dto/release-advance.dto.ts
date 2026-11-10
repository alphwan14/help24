import { IsNotEmpty, IsString } from 'class-validator';

/** The customer's "Send materials money" (Materials Advance, migration 139). */
export class ReleaseAdvanceDto {
  @IsString()
  @IsNotEmpty()
  user_id!: string;
}
