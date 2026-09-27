import { IsIn, IsString, Matches, MaxLength, MinLength } from 'class-validator';

/** Record that finance paid a ruling's share by hand. The AMOUNT is never sent — it comes from the ruling. */
export class ManualSettlementDto {
  @IsIn(['provider_payout', 'client_refund'])
  direction: 'provider_payout' | 'client_refund';

  /** The M-Pesa code or bank reference of the payment finance made. */
  @IsString()
  @Matches(/^[A-Za-z0-9][A-Za-z0-9 ._/#-]{2,63}$/, { message: 'Give the payment reference: 3–64 letters, digits or . _ / # -' })
  reference: string;

  @IsString()
  @MinLength(5)
  @MaxLength(1000)
  reason: string;
}

/** Apply the ruling already on record to money a legacy resolve left frozen. */
export class ApplyRulingDto {
  @IsString()
  @MinLength(5)
  @MaxLength(1000)
  reason: string;
}
