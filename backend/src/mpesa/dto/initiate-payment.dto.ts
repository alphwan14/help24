import { IsString, IsNotEmpty, Matches } from 'class-validator';

export class InitiatePaymentDto {
  @IsString()
  @IsNotEmpty()
  post_id!: string;

  // Buyer's own phone for the M-Pesa STK prompt.
  @IsString()
  @Matches(/^254\d{9}$/, {
    message: 'buyer_phone must be a valid Kenyan number (254XXXXXXXXX)',
  })
  buyer_phone!: string;

  // Firebase UID of the authenticated buyer.
  @IsString()
  @IsNotEmpty()
  buyer_user_id!: string;
}
