import { IsIn, IsOptional, IsString, MaxLength, ValidateIf } from 'class-validator';

export class ListVerificationsQueryDto {
  @IsOptional()
  @IsIn(['pending', 'approved', 'rejected'])
  status?: 'pending' | 'approved' | 'rejected';
}

export class ReviewVerificationDto {
  @IsIn(['approve', 'reject'])
  decision: 'approve' | 'reject';

  /** Required to reject: it is sent to the provider. */
  @ValidateIf((o: ReviewVerificationDto) => o.decision === 'reject' || o.reason !== undefined)
  @IsString()
  @MaxLength(500)
  reason?: string;
}
