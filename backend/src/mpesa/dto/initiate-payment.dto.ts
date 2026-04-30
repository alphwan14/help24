import { IsString, IsNotEmpty } from 'class-validator';

export class InitiatePaymentDto {
  @IsString()
  @IsNotEmpty()
  post_id!: string;

  @IsString()
  @IsNotEmpty()
  buyer_user_id!: string;
}
