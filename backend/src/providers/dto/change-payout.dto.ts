import { IsUUID, IsString, Matches } from 'class-validator';

export class ChangePayoutDto {
  @IsUUID('4')
  provider_id!: string;

  @IsString()
  @Matches(/^2547\d{8}$/, {
    message: 'new_phone_payout must be a valid Safaricom number (2547XXXXXXXX)',
  })
  new_phone_payout!: string;
}
