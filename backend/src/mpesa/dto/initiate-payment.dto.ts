import { IsBoolean, IsNotEmpty, IsOptional, IsString } from 'class-validator';

export class InitiatePaymentDto {
  @IsString()
  @IsNotEmpty()
  post_id!: string;

  @IsString()
  @IsNotEmpty()
  buyer_user_id!: string;

  /**
   * Pay with Materials Advance (migration 139). Absent on every app before
   * it, which pays the normal way. Refused unless the job qualifies.
   */
  @IsOptional()
  @IsBoolean()
  materials_advance?: boolean;
}
