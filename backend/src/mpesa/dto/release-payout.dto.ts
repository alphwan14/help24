import { IsString, IsNotEmpty, MaxLength, MinLength } from 'class-validator';

export class ReleasePayoutDto {
  @IsString()
  @IsNotEmpty()
  post_id!: string;
}

/**
 * POST /mpesa/release-payout, an admin sending a payout by hand. Says why:
 * the reason is recorded with the admin's name before any money moves.
 */
export class AdminReleasePayoutDto extends ReleasePayoutDto {
  @IsString()
  @MinLength(5)
  @MaxLength(1000)
  reason!: string;
}
