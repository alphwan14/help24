import { IsIn, IsOptional, IsString, IsUUID, MaxLength } from 'class-validator';

export class ApproveDto {
  @IsUUID()
  post_id: string;

  /** Firebase UID of the client (post author) approving. */
  @IsString()
  client_user_id: string;
}

export class DisputeDto {
  @IsUUID()
  post_id: string;

  /** Firebase UID of the client raising the dispute. */
  @IsString()
  client_user_id: string;

  @IsString()
  @MaxLength(1000)
  reason: string;
}
