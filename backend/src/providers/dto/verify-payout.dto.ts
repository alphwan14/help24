import { IsString, IsNotEmpty, IsUUID, Length } from 'class-validator';

export class VerifyPayoutDto {
  @IsUUID('4')
  provider_id!: string;

  @IsString()
  @IsNotEmpty()
  @Length(6, 6, { message: 'otp_code must be exactly 6 digits' })
  otp_code!: string;
}
