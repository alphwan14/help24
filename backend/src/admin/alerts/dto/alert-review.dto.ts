import { IsIn, IsOptional, IsString, Matches, MaxLength } from 'class-validator';

/**
 * Review an alert, or reopen one. The fingerprint is the one the admin was
 * looking at; the service refuses it if the alert has changed since.
 */
export class AlertReviewDto {
  @IsIn(['reviewed', 'reopened'])
  action: 'reviewed' | 'reopened';

  @Matches(/^[0-9a-f]{16}$/)
  fingerprint: string;

  /** Required to mark reviewed (checked in the service): why it needs nothing more. */
  @IsOptional()
  @IsString()
  @MaxLength(500)
  note?: string;
}
