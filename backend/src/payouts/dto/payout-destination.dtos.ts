import {
  IsBoolean,
  IsNotEmpty,
  IsOptional,
  IsString,
  Length,
  Matches,
  MaxLength,
  MinLength,
} from 'class-validator';

/**
 * Every DTO carries `user_id` because `@Auth('body.user_id')` /
 * `@Auth('query.user_id')` rewrites it to the token-verified uid before
 * validation runs — the service can then trust it as the owner without a
 * second lookup. See auth.decorator.ts.
 */

export class ListDestinationsQueryDto {
  @IsString()
  @IsNotEmpty()
  user_id!: string;
}

export class AddDestinationDto {
  @IsString()
  @IsNotEmpty()
  user_id!: string;

  /**
   * Raw as typed — `0712…`, `+254712…`, `712…` are all accepted. The service
   * normalises via the same `normalizeMsisdn` that the payout path uses, then
   * additionally requires a Safaricom (`2547…`) number because M-Pesa B2C is
   * the only channel.
   */
  @IsString()
  @IsNotEmpty()
  @MaxLength(20)
  msisdn!: string;
}

export class RequestChallengeDto {
  @IsString()
  @IsNotEmpty()
  user_id!: string;
}

export class VerifyChallengeDto {
  @IsString()
  @IsNotEmpty()
  user_id!: string;

  @IsString()
  @Length(6, 6, { message: 'code must be exactly 6 digits' })
  @Matches(/^\d{6}$/, { message: 'code must be exactly 6 digits' })
  code!: string;

  /** Default true: the number just proven becomes where money goes. */
  @IsOptional()
  @IsBoolean()
  make_default?: boolean;
}

export class SetDefaultDto {
  @IsString()
  @IsNotEmpty()
  user_id!: string;
}

export class RetireDestinationDto {
  @IsString()
  @IsNotEmpty()
  user_id!: string;

  /**
   * Mandatory by design — `fn_retire_payout_destination` refuses without one:
   * "An unexplained retirement cannot be told apart from an attack."
   */
  @IsString()
  @MinLength(3)
  @MaxLength(200)
  reason!: string;
}
