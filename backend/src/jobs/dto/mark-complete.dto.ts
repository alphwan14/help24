import { IsOptional, IsString, IsUUID, MaxLength } from 'class-validator';

export class MarkCompleteDto {
  @IsUUID()
  post_id: string;

  /** Firebase UID of the provider making this request. */
  @IsString()
  provider_user_id: string;

  @IsOptional()
  @IsString()
  @MaxLength(500)
  provider_note?: string;
}
