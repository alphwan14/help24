import { IsIn, IsString, MaxLength, MinLength } from 'class-validator';

/** Every admin action on a payment says why. Recorded with the admin's name. */
export class AdminReasonDto {
  @IsString()
  @MinLength(5)
  @MaxLength(1000)
  reason: string;
}

/** POST /admin/transactions/:id/open-dispute */
export class AdminOpenDisputeDto extends AdminReasonDto {
  /** Whose dispute it is: the client who paid, or the provider. */
  @IsIn(['client', 'provider'])
  raised_by: 'client' | 'provider';
}
