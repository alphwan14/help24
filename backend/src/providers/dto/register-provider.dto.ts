import {
  IsString,
  IsNotEmpty,
  IsArray,
  MinLength,
  ArrayMinSize,
  Matches,
} from 'class-validator';

export class RegisterProviderDto {
  @IsString()
  @IsNotEmpty()
  @MinLength(2)
  name!: string;

  @IsString()
  @Matches(/^254\d{9}$/, {
    message: 'phone_login must be a valid Kenyan number (254XXXXXXXXX)',
  })
  phone_login!: string;

  @IsString()
  @Matches(/^2547\d{8}$/, {
    message: 'phone_payout must be a valid Safaricom number (2547XXXXXXXX)',
  })
  phone_payout!: string;

  @IsArray()
  @IsString({ each: true })
  @ArrayMinSize(1)
  services!: string[];

  @IsString()
  @IsNotEmpty()
  location!: string;
}
